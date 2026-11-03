-module(parvi_native_tests).
-include_lib("eunit/include/eunit.hrl").

native_foundation_test_() ->
    {setup,
     fun() -> {ok, _} = parvi:start(native_cluster) end,
     fun(_) -> application:stop(parvi), application:unset_env(parvi, runtime_profile) end,
     [fun standard_workers/0, fun observer_lifetime/0, fun observer_survives_chat_restart/0,
      fun scope_restart/0]}.

standard_workers() ->
    ?assertEqual([parvi_chat, parvi_clock_sup, parvi_pg], lists:sort([Id || {Id, _, _, _} <- supervisor:which_children(parvi_sup)])),
    [?assertEqual(undefined, whereis(Name)) || Name <-
        [parvi_swarms, parvi_relay, parvi_direct, parvi_discovery, parvi_network]],
    ?assertEqual([node()], maps:get(chat_nodes, parvi:status())),
    ?assertMatch({error, {already_started, parvi}}, parvi:start(native_cluster)).

observer_lifetime() ->
    Parent = self(),
    {Pid, Ref} = spawn_monitor(fun() ->
        ok = parvi:subscribe(), Parent ! observer_ready, receive stop -> ok end
    end),
    receive observer_ready -> ok after 1000 -> error(observer_timeout) end,
    ?assertEqual(1, maps:get(subscriber_count, parvi:status())),
    Pid ! stop,
    receive {'DOWN', Ref, process, Pid, normal} -> ok after 1000 -> error(observer_did_not_stop) end,
    await(fun() -> maps:get(subscriber_count, parvi:status()) =:= 0 end, 100).

observer_survives_chat_restart() ->
    ok = parvi:subscribe(), ok = parvi:subscribe(),
    Old = whereis(parvi_chat), exit(Old, kill),
    await(fun() -> is_pid(whereis(parvi_chat)) andalso whereis(parvi_chat) =/= Old end, 100),
    ?assertEqual(1, maps:get(subscriber_count, parvi:status())),
    ?assertEqual(1, maps:get(chat_process_count, parvi:status())),
    {ok, Message} = parvi:send(<<"Observer survives worker restart">>),
    receive {parvi_message, Message} -> ok after 1000 -> error(missing_observer_message) end,
    receive {parvi_message, Message} -> error(duplicate_observer_message) after 0 -> ok end,
    ok = parvi:unsubscribe(), ok = parvi:unsubscribe().

scope_restart() ->
    ok = parvi:subscribe(),
    Chat = whereis(parvi_chat), Scope = whereis(parvi_pg), exit(Scope, kill),
    await(fun() -> is_pid(whereis(parvi_chat)) andalso whereis(parvi_chat) =/= Chat end, 100),
    ?assertEqual(0, maps:get(subscriber_count, parvi:status())),
    ?assertEqual([node()], maps:get(chat_nodes, parvi:status())),
    ok = parvi:subscribe(),
    {ok, Message} = parvi:send(<<"Scope membership restored">>),
    receive {parvi_message, Message} -> ok after 1000 -> error(scope_recovery_failed) end,
    ok = parvi:unsubscribe().

await(_, 0) -> error(state_did_not_converge);
await(Predicate, Attempts) ->
    case Predicate() of true -> ok; false -> timer:sleep(10), await(Predicate, Attempts - 1) end.
