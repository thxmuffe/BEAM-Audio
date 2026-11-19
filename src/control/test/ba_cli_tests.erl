-module(ba_cli_tests).
-include_lib("eunit/include/eunit.hrl").
-export([idle_link/0,close/1]).
close(_) -> ok.
idle_link() -> {ok,spawn_link(fun Loop() -> receive stop -> ok;_ -> Loop() end end)}.

command_parser_and_no_restore_command_test() ->
    Spec=ba_cli:spec("/tmp"),
    ?assertMatch({ok,#{enable := "speaker"},_,_},argparse:parse(["new","device","--devicename","one","--createbuffee","--enable","speaker"],Spec,#{progname => "beam-audio"})),
    ?assertMatch({error,_},argparse:parse(["start","device","--devicename","one"],Spec,#{progname => "beam-audio"})),
    ?assertMatch({ok,#{web_assets := "/tmp",web_port := 0},_,_},
        argparse:parse(["new","device","--devicename","one","--web-assets","/tmp","--web-port","0"],Spec,#{progname => "beamaudio"})),
    ?assertMatch({ok,#{devicename := "one",all := true},_,_},
        argparse:parse(["monitor","--all","--devicename","one"],Spec,#{progname => "beamaudio"})),
    ?assertMatch({ok,#{no_user_state := true,all := true},_,_},
        argparse:parse(["monitor","--all","--no-user-state"],Spec,#{progname => "beamaudio"})),
    ?assertNot(ba_cli_store:valid_name("../other")),?assert(ba_cli_store:valid_name("test-1")).

readiness_needs_real_work_and_fresh_progress_test() ->
    Base=#{buffee => #{state => authorized},consent => #{speaker => true,microphone => false,broadcast => true},
        clock => #{state => synchronized,offset_policy => #{ready => true}},
        handler => #{audio => #{broadcast => #{state => starting}}},audio => #{}},
    ?assertNot(maps:get(ready,ba_device_api:readiness(Base))),
    Active=Base#{handler := #{audio => #{broadcast => #{state => running,blocks => 4}}},
        audio := #{subscriptions => #{one => #{state => active,playing => true,mix_ready => true}},mixer => #{rendered => 8}}},
    ?assert(maps:get(ready,ba_device_api:readiness(Active))),
    ?assert(maps:get('audio-flowing',ba_device_api:readiness(Active,#{<<"broadcast">> => 3,<<"speaker">> => 7}))),
    ?assertNot(maps:get('audio-flowing',ba_device_api:readiness(Active,#{<<"broadcast">> => 4,<<"speaker">> => 8}))),
    NoSink=Active#{audio := #{subscriptions => #{one => #{state => active,playing => true,mix_ready => false}},mixer => #{rendered => 8}}},
    ?assertNot(maps:get('audio-flowing',ba_device_api:readiness(NoSink,#{}))),
    ?assertNot(maps:get(ready,ba_device_api:readiness(Active#{clock := #{state => holdover}}))).

helper_environment_does_not_receive_seed_test() ->
    Old=os:getenv("BA_IDENTITY_SEED"),os:putenv("BA_IDENTITY_SEED","must-stay-in-parent"),
    try
        Python=case os:find_executable("python3") of false -> os:find_executable("python");P -> P end,
        Port=open_port({spawn_executable,Python},[binary,exit_status,{env,ba_native_env:without_secrets()},
            {args,["-c","import os; assert 'BA_IDENTITY_SEED' not in os.environ; print('scrubbed')"]}]),
        %% Windows Python ends the line with \r\n.
        receive {Port,{data,<<"scrubbed",_/binary>>}} -> ok after 3000 -> error(helper_environment_failed) end,
        receive {Port,{exit_status,0}} -> ok after 3000 -> error(helper_failed) end,
        ?assertEqual("must-stay-in-parent",os:getenv("BA_IDENTITY_SEED"))
    after case Old of false -> os:unsetenv("BA_IDENTITY_SEED");_ -> os:putenv("BA_IDENTITY_SEED",Old) end end.

