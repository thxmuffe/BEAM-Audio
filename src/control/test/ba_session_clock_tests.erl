-module(ba_session_clock_tests).
-include_lib("eunit/include/eunit.hrl").

%% The system clock makes the clock usable at once; Session time is UTC.
system_reference_test() ->
    with_clock(#{clock_reference => system},fun() ->
        #{state := synchronized,timeline := <<"utc">>,source := system,utc_time_ns := UTC}=ba_session_clock:status(),
        ?assert(abs(UTC-erlang:system_time(nanosecond))<50000000),
        ?assertEqual(<<"utc">>,ba_session_clock:id())
    end).

%% An unreachable time server leaves the system reading in place and says why.
unreachable_server_keeps_system_time_test() ->
    with_clock(#{clock_reference => {ntp,"127.0.0.1",9},clock_interval_ms => 100},fun() ->
        await(fun() -> maps:get(last_error,ba_session_clock:status())=/=null end),
        ?assertMatch(#{state := synchronized,source := system},ba_session_clock:status())
    end).

resync_replaces_the_pending_read_timer_test() ->
    with_clock(#{clock_reference => {ntp,"127.0.0.1",9},clock_interval_ms => 60000},fun() ->
        Pid=whereis(ba_session_clock),
        {ok,Old}=read_timer(Pid),
        [ba_session_clock:resync(network_changed) || _ <- lists:seq(1,3)],
        #{timer := undefined,query := {Worker,Monitor}}=sys:get_state(Pid),
        ?assertEqual(false,erlang:read_timer(Old)),
        Pid ! {timeout,Old,read},
        ?assertMatch(#{timer := undefined,query := {Worker,Monitor}},sys:get_state(Pid)),
        {ok,New}=read_timer(Pid),
        ?assertNotEqual(Old,New),
        Pid ! {timeout,Old,read},
        ?assertMatch(#{timer := New,query := undefined},sys:get_state(Pid))
    end).

read_timer(Pid) ->
    await(fun() -> is_reference(maps:get(timer,sys:get_state(Pid))) end),
    {ok,maps:get(timer,sys:get_state(Pid))}.

with_clock(Env,Fun) ->
    application:load(ba_core),
    Keys=maps:keys(Env),
    [application:set_env(ba_core,K,V) || {K,V} <- maps:to_list(Env)],
    {ok,Pid}=ba_session_clock:start_link(),
    try Fun() after unlink(Pid),gen_server:stop(Pid),[application:unset_env(ba_core,K) || K <- Keys] end.

await(F) -> await(F,100).
await(F,0) -> ?assert(F());
await(F,N) -> case F() of true -> ok;false -> timer:sleep(20),await(F,N-1) end.
