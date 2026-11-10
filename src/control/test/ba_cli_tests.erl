-module(ba_cli_tests).
-include_lib("eunit/include/eunit.hrl").
-export([idle_link/0,close/1]).
close(_) -> ok.
idle_link() -> {ok,spawn_link(fun Loop() -> receive stop -> ok;_ -> Loop() end end)}.

command_parser_and_no_restore_command_test() ->
    Spec=ba_cli:spec("/tmp"),
    ?assertMatch({ok,#{enable := "speaker"},_,_},argparse:parse(["new","device","--devicename","one","--createswarm","--enable","speaker"],Spec,#{progname => "beam-audio"})),
    ?assertMatch({error,_},argparse:parse(["start","device","--devicename","one"],Spec,#{progname => "beam-audio"})),
    ?assertMatch({ok,#{web_assets := "/tmp",web_port := 0},_,_},
        argparse:parse(["new","device","--devicename","one","--web-assets","/tmp","--web-port","0"],Spec,#{progname => "beamaudio"})),
    ?assertMatch({ok,#{devicename := "one",all := true},_,_},
        argparse:parse(["monitor","--all","--devicename","one"],Spec,#{progname => "beamaudio"})),
    ?assertNot(ba_cli_store:valid_name("../other")),?assert(ba_cli_store:valid_name("test-1")).

readiness_needs_real_work_and_fresh_progress_test() ->
    Base=#{swarm => #{state => authorized},consent => #{speaker => true,microphone => false,broadcast => true},
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
        Python=os:find_executable("python3"),
        Port=open_port({spawn_executable,Python},[binary,exit_status,{env,ba_native_env:without_secrets()},
            {args,["-c","import os; assert 'BA_IDENTITY_SEED' not in os.environ; print('scrubbed')"]}]),
        receive {Port,{data,<<"scrubbed\n">>}} -> ok after 3000 -> error(helper_environment_failed) end,
        receive {Port,{exit_status,0}} -> ok after 3000 -> error(helper_failed) end,
        ?assertEqual("must-stay-in-parent",os:getenv("BA_IDENTITY_SEED"))
    after case Old of false -> os:unsetenv("BA_IDENTITY_SEED");_ -> os:putenv("BA_IDENTITY_SEED",Old) end end.

output_failure_preserves_audio_processes_test() ->
    OldProfile=application:get_env(ba_core,runtime_profile),
    OldState=os:getenv("BA_STATE_DIR"),os:unsetenv("BA_STATE_DIR"),
    Control=spawn(fun Loop() -> receive _ -> Loop() end end),register(ba_swarm_control,Control),
    try
        {ok,Sup}=ba_audio_sup:start_link(),
        try
            Mixer=whereis(ba_audio_mixer),Receiver=whereis(ba_audio_receiver),
            {ok,Source}=supervisor:start_child(Sup,#{id => source_sentinel,start => {?MODULE,idle_link,[]}}),
            {ok,Session}=supervisor:start_child(Sup,#{id => session_sentinel,start => {?MODULE,idle_link,[]}}),
            Socket=make_ref(),
            sys:replace_state(Mixer,fun(S) -> S#{owner => Receiver,device := {?MODULE,#{socket => Socket}}} end),
            Mixer ! {tcp_closed,Socket},
            %% A synchronous status request is ordered after the simulated closure.
            ?assertEqual(output_closed,maps:get(last_error,ba_audio_mixer:status())),
            ?assertEqual(Mixer,whereis(ba_audio_mixer)),?assertEqual(Receiver,whereis(ba_audio_receiver)),
            ?assert(is_process_alive(Source)),?assert(is_process_alive(Session)),
            ?assertMatch({ok,#{device := undefined}}, {ok,sys:get_state(Mixer)})
        after gen_server:stop(Sup) end
    after
        exit(Control,kill),
        case whereis(ba_swarm_control) of undefined -> ok;_ -> unregister(ba_swarm_control) end,
        case OldProfile of undefined -> application:unset_env(ba_core,runtime_profile);{ok,P} -> application:set_env(ba_core,runtime_profile,P) end,
        case OldState of false -> os:unsetenv("BA_STATE_DIR");_ -> os:putenv("BA_STATE_DIR",OldState) end
    end.
