-module(ba_native_tests).
-include_lib("eunit/include/eunit.hrl").

native_foundation_test_() ->
    {setup,
     fun() -> {ok, _} = ba_runtime:start(native_cluster) end,
     fun(_) -> application:stop(ba_core), application:unset_env(ba_core, runtime_profile) end,
     [fun standard_workers/0, fun observer_lifetime/0, fun observer_survives_chat_restart/0,
      fun scope_restart/0]}.

standard_workers() ->
    ?assertEqual([ba_chat, ba_swarm_clock_sup, ba_pg], lists:sort([Id || {Id, _, _, _} <- supervisor:which_children(ba_sup)])),
    [?assertEqual(undefined, whereis(Name)) || Name <-
        [ba_swarms, ba_relay, ba_direct, ba_discovery, ba_network]],
    ?assertEqual([node()], maps:get(chat_nodes, ba_runtime:status())),
    ?assertMatch({error, {already_started, ba_core}}, ba_runtime:start(native_cluster)).

observer_lifetime() ->
    Parent = self(),
    {Pid, Ref} = spawn_monitor(fun() ->
        ok = ba_runtime:subscribe(), Parent ! observer_ready, receive stop -> ok end
    end),
    receive observer_ready -> ok after 1000 -> error(observer_timeout) end,
    ?assertEqual(1, maps:get(subscriber_count, ba_runtime:status())),
    Pid ! stop,
    receive {'DOWN', Ref, process, Pid, normal} -> ok after 1000 -> error(observer_did_not_stop) end,
    await(fun() -> maps:get(subscriber_count, ba_runtime:status()) =:= 0 end, 100).

observer_survives_chat_restart() ->
    ok = ba_runtime:subscribe(), ok = ba_runtime:subscribe(),
    Old = whereis(ba_chat), exit(Old, kill),
    await(fun() -> is_pid(whereis(ba_chat)) andalso whereis(ba_chat) =/= Old end, 100),
    ?assertEqual(1, maps:get(subscriber_count, ba_runtime:status())),
    ?assertEqual(1, maps:get(chat_process_count, ba_runtime:status())),
    {ok, Message} = ba_runtime:send(<<"Observer survives worker restart">>),
    receive {ba_message, Message} -> ok after 1000 -> error(missing_observer_message) end,
    receive {ba_message, Message} -> error(duplicate_observer_message) after 0 -> ok end,
    ok = ba_runtime:unsubscribe(), ok = ba_runtime:unsubscribe().

scope_restart() ->
    ok = ba_runtime:subscribe(),
    Chat = whereis(ba_chat), Scope = whereis(ba_pg), exit(Scope, kill),
    await(fun() -> is_pid(whereis(ba_chat)) andalso whereis(ba_chat) =/= Chat end, 100),
    ?assertEqual(0, maps:get(subscriber_count, ba_runtime:status())),
    ?assertEqual([node()], maps:get(chat_nodes, ba_runtime:status())),
    ok = ba_runtime:subscribe(),
    {ok, Message} = ba_runtime:send(<<"Scope membership restored">>),
    receive {ba_message, Message} -> ok after 1000 -> error(scope_recovery_failed) end,
    ok = ba_runtime:unsubscribe().

await(_, 0) -> error(state_did_not_converge);
await(Predicate, Attempts) ->
    case Predicate() of true -> ok; false -> timer:sleep(10), await(Predicate, Attempts - 1) end.
