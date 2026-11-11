%% Native wx graph/model over a relay, with no Distributed Erlang node name.
-module(ba_relay_ui_smoke).
-export([main/0]).
main() ->
    try exercise(), io:format("PASS: native relay graph, scoped send and UI rebuild preserve relay identity/membership~n"), halt(0)
    catch Class:Reason:Stack ->
        Safe = case is_atom(Reason) of true -> Reason; false -> assertion_failed end,
        io:format("FAIL: ~p ~p at ~p~n", [Class, Safe, [{M,F,proplists:get_value(line, Info)} || {M,F,_,Info} <- Stack]]), halt(1)
    end.
exercise() ->
    {ok, _} = ba_runtime:start(), nonode@nohost = node(),
    await(fun() -> maps:get(connected, ba_relay:status()) end),
    Reply = json:decode(ba_bridge:request(iolist_to_binary(json:encode(#{method => join_buffee,
        invitation => list_to_binary(os:getenv("BA_TEST_INVITATION"))})))),
    null = maps:get(<<"error">>, Reply),
    #{<<"buffee_id">> := Buffee} = maps:get(<<"result">>, Reply),
    Identity = ba_relay:id(), Relay = whereis(ba_relay), Buffees = whereis(ba_buffees),
    {Host, Monitor} = spawn_monitor(fun() -> os_windows_host:run(#{selected => Buffee}) end),
    await(fun() -> whereis(os_windows_host) =/= undefined end),
    await(fun() ->
        #{pid := Pid} = os_windows_host:status(),
        case Pid of
            undefined -> false;
            _ -> [_, S, os_windows, _] = sys:get_state(Pid),
                 map_size(maps:get(nodes, maps:get(graph, S))) =:= 2
        end
    end),
    os_windows_model:put(#{drafts => #{Buffee => "native relay send"}}), Ref = make_ref(),
    os_windows_model:request(#{method => send_buffee, buffee_id => Buffee, text => <<"native relay send">>}, send, self(), Ref),
    receive {reply, Ref, send, #{<<"error">> := null}} -> ok after 3000 -> error(send_timeout) end,
    os_windows_host:reload(),
    await(fun() -> maps:get(generation, os_windows_host:status()) =:= 1 end),
    Identity = ba_relay:id(), Relay = whereis(ba_relay), Buffees = whereis(ba_buffees),
    "" = os_windows_model:draft(os_windows_model:get()),
    #{pid := Closing} = os_windows_host:status(), wx_object:stop(Closing, normal, 5000),
    receive {'DOWN', Monitor, process, Host, normal} -> ok after 5000 -> error(close_timeout) end.
await(Fun) -> await(Fun, 200).
await(_, 0) -> error(timeout);
await(Fun, N) -> case Fun() of true -> ok; false -> timer:sleep(50), await(Fun, N-1) end.
