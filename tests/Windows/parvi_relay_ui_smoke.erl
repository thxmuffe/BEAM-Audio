%% Native wx graph/model over a relay, with no Distributed Erlang node name.
-module(parvi_relay_ui_smoke).
-export([main/0]).
main() ->
    try exercise(), io:format("PASS: native relay graph, scoped send and UI rebuild preserve relay identity/membership~n"), halt(0)
    catch Class:Reason:Stack ->
        Safe = case is_atom(Reason) of true -> Reason; false -> assertion_failed end,
        io:format("FAIL: ~p ~p at ~p~n", [Class, Safe, [{M,F,proplists:get_value(line, Info)} || {M,F,_,Info} <- Stack]]), halt(1)
    end.
exercise() ->
    {ok, _} = parvi:start(), nonode@nohost = node(),
    await(fun() -> maps:get(connected, parvi_relay:status()) end),
    Reply = json:decode(parvi_bridge:request(iolist_to_binary(json:encode(#{method => join_swarm,
        invitation => list_to_binary(os:getenv("PARVI_TEST_INVITATION"))})))),
    null = maps:get(<<"error">>, Reply),
    #{<<"swarm_id">> := Swarm} = maps:get(<<"result">>, Reply),
    Identity = parvi_relay:id(), Relay = whereis(parvi_relay), Swarms = whereis(parvi_swarms),
    {Host, Monitor} = spawn_monitor(fun() -> parvi_windows_host:run(#{selected => Swarm}) end),
    await(fun() -> whereis(parvi_windows_host) =/= undefined end),
    await(fun() ->
        #{pid := Pid} = parvi_windows_host:status(),
        case Pid of
            undefined -> false;
            _ -> [_, S, parvi_windows, _] = sys:get_state(Pid),
                 map_size(maps:get(nodes, maps:get(graph, S))) =:= 2
        end
    end),
    parvi_windows_model:put(#{drafts => #{Swarm => "native relay send"}}), Ref = make_ref(),
    parvi_windows_model:request(#{method => send_swarm, swarm_id => Swarm, text => <<"native relay send">>}, send, self(), Ref),
    receive {reply, Ref, send, #{<<"error">> := null}} -> ok after 3000 -> error(send_timeout) end,
    parvi_windows_host:reload(),
    await(fun() -> maps:get(generation, parvi_windows_host:status()) =:= 1 end),
    Identity = parvi_relay:id(), Relay = whereis(parvi_relay), Swarms = whereis(parvi_swarms),
    "" = parvi_windows_model:draft(parvi_windows_model:get()),
    #{pid := Closing} = parvi_windows_host:status(), wx_object:stop(Closing, normal, 5000),
    receive {'DOWN', Monitor, process, Host, normal} -> ok after 5000 -> error(close_timeout) end.
await(Fun) -> await(Fun, 200).
await(_, 0) -> error(timeout);
await(Fun, N) -> case Fun() of true -> ok; false -> timer:sleep(50), await(Fun, N-1) end.
