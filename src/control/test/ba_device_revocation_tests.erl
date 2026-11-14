-module(ba_device_revocation_tests).
-behaviour(gen_server).
-include_lib("eunit/include/eunit.hrl").
-export([init/1,handle_call/3,handle_cast/2,handle_info/2]).

barrier_and_generation_test() -> fixture(fun() ->
    ok=ba_device_config:change(#{speaker => true},#{}),
    {ok,A}=gen_server:start(?MODULE,{self(),ok},[]),
    {ok,B}=gen_server:start(?MODULE,{self(),ok},[]),
    try
        Token=gen_server:call(A,token),
        ok=ba_device_config:change(#{speaker => false},#{}),
        ?assertEqual(false,ba_device_permission:allowed(playback)),
        receive {stopped,A,false} -> ok after 100 -> error(no_first_ack) end,
        receive {stopped,B,false} -> ok after 100 -> error(no_second_ack) end,
        ok=ba_device_config:change(#{speaker => true},#{}),
        ?assertNot(ba_device_permission:valid(playback,Token)),
        ?assertEqual(stale,gen_server:call(A,write)),
        {ok,Fresh}=ba_device_config:token(speaker),
        ?assert(ba_device_permission:valid(playback,Fresh))
    after gen_server:stop(A),gen_server:stop(B) end
end).

acknowledgement_waits_for_executor_test() -> fixture(fun() ->
    ok=ba_device_config:change(#{speaker => true},#{}),
    {ok,A}=gen_server:start(?MODULE,{self(),hold},[]),Parent=self(),
    try
        spawn(fun() -> Parent ! {off_result,ba_device_config:change(#{speaker => false},#{})} end),
        receive {stopped,A,false} -> ok after 1000 -> error(no_stop_request) end,
        ?assertNot(ba_device_permission:allowed(playback)),
        receive {off_result,_} -> error(acknowledged_too_early) after 0 -> ok end,
        A ! continue,
        receive {off_result,ok} -> ok after 1000 -> error(no_completion) end
    after gen_server:stop(A) end
end).

failed_ack_blocks_regrant_test() -> fixture(fun() ->
    ok=ba_device_config:change(#{speaker => true},#{}),
    {ok,A}=gen_server:start(?MODULE,{self(),fail},[]),
    try
        ?assertEqual({error,revocation_incomplete},ba_device_config:change(#{speaker => false},#{})),
        ?assertNot(ba_device_permission:allowed(playback)),
        ?assertEqual([speaker],maps:get(revocation_pending,ba_device_config:snapshot())),
        ?assertEqual({error,revocation_incomplete},ba_device_config:change(#{speaker => true},#{})),
        ok=gen_server:call(A,{mode,ok}),
        ok=ba_device_config:change(#{speaker => false},#{}),
        ?assertEqual([],maps:get(revocation_pending,ba_device_config:snapshot())),
        ok=ba_device_config:change(#{speaker => true},#{})
    after gen_server:stop(A) end
end).

lost_executor_does_not_fake_ack_test() -> fixture(fun() ->
    ok=ba_device_config:change(#{speaker => true},#{}),
    {ok,A}=gen_server:start(?MODULE,{self(),fail},[]),
    ?assertEqual({error,revocation_incomplete},ba_device_config:change(#{speaker => false},#{})),
    gen_server:stop(A),
    ?assertEqual({error,revocation_incomplete},ba_device_config:change(#{speaker => false},#{})),
    ?assertEqual({error,revocation_incomplete},ba_device_config:change(#{speaker => true},#{}))
end).

registry_loss_denies_existing_handles_test() -> fixture(fun() ->
    ok=ba_device_config:change(#{speaker => true},#{}),
    {ok,T}=ba_device_config:token(speaker),
    gen_server:stop(ba_permission_pg),{ok,_}=pg:start_link(ba_permission_pg),
    ?assertNot(ba_device_permission:valid(playback,T)),
    ?assertNot(ba_device_permission:allowed(playback)),
    ?assertEqual({error,permission_registry_lost},ba_device_config:change(#{speaker => false},#{}))
end).

init({Parent,Mode}) ->
    {ok,Token}=ba_device_permission:enter(playback),{ok,#{parent => Parent,mode => Mode,token => Token}}.
handle_call(token,_,S) -> {reply,maps:get(token,S),S};
handle_call(write,_,S) -> {reply,case ba_device_permission:valid(playback,maps:get(token,S)) of true -> written;false -> stale end,S};
handle_call({mode,Mode},_,S) -> {reply,ok,S#{mode := Mode}};
handle_call({revoke_permissions,_},_,S) ->
    maps:get(parent,S) ! {stopped,self(),ba_device_permission:allowed(playback)},
    {reply,case maps:get(mode,S) of hold -> receive continue -> ok end;ok -> ok;fail -> {error,native_stop_unconfirmed} end,S}.
handle_cast(_,S) -> {noreply,S}.
handle_info(_,S) -> {noreply,S}.

fixture(F) ->
    Old=application:get_env(ba_core,runtime_profile),DirEnv=os:getenv("BA_STATE_DIR"),
    os:unsetenv("BA_STATE_DIR"),application:set_env(ba_core,runtime_profile,buffee_control),
    {ok,_}=pg:start_link(ba_permission_pg),{ok,C}=ba_device_config:start_link(),
    try F() after
        gen_server:stop(C),gen_server:stop(ba_permission_pg),
        case Old of undefined -> application:unset_env(ba_core,runtime_profile);{ok,V} -> application:set_env(ba_core,runtime_profile,V) end,
        case DirEnv of false -> os:unsetenv("BA_STATE_DIR");_ -> os:putenv("BA_STATE_DIR",DirEnv) end
    end.
