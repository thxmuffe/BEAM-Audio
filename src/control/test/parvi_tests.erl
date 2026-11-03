-module(parvi_tests).
-include_lib("eunit/include/eunit.hrl").

connection_string_roundtrip_test() ->
    Node = <<"parvi_windows_123@127.0.0.1">>,
    Cookie = <<"secret+/=&?%">>,
    String = parvi_connection:format(Node, Cookie),
    ?assertEqual({ok, #{node => Node, cookie => Cookie}}, parvi_connection:parse(String)),
    ?assertEqual(parvi_connection:parse(String), parvi_connection:parse(<<" \n", String/binary, "\r\n">>)).

invalid_connection_strings_test() ->
    Prefix = <<"parvi://connect/v1?">>,
    Bad = [<<>>, <<"not a connection string">>,
        <<"https://connect/v1?node=a&cookie=b">>,
        <<"parvi://connect/v2?node=a&cookie=b">>,
        <<Prefix/binary, "node=a">>, <<Prefix/binary, "node=a&cookie=">>,
        <<Prefix/binary, "node=a&cookie=b&cookie=c">>,
        <<Prefix/binary, "node=a&cookie=b&extra=c">>,
        <<Prefix/binary, "node=a&cookie=b#fragment">>,
        <<"parvi://user@connect/v1?node=a&cookie=b">>,
        <<Prefix/binary, "node=a&cookie=%00">>,
        <<Prefix/binary, "node=a&cookie=%FF">>,
        <<Prefix/binary, "node=a&cookie=", (binary:copy(<<"x">>, 129))/binary>>,
        binary:copy(<<"x">>, 2049), 123],
    [?assertEqual({error, invalid_connection_string}, parvi_connection:parse(Input)) || Input <- Bad].

chat_test_() ->
    {setup, fun() -> application:set_env(parvi, reception_desk_url, undefined), {ok, _} = parvi:start() end,
     fun(_) -> application:stop(parvi) end,
     [fun messaging/0, fun validation_and_bounds/0, fun bridge_request/0, fun restart/0]}.

bridge_request() ->
    Reply = json:decode(parvi_bridge:request(<<"{\"method\":\"send\",\"text\":\"native host\"}">>)),
    ?assertEqual(null, maps:get(<<"error">>, Reply)),
    ?assertEqual(<<"native host">>, maps:get(<<"text">>, lists:last(maps:get(<<"messages">>, Reply)))),
    Invalid = json:decode(parvi_bridge:request(<<"not json">>)),
    ?assert(is_binary(maps:get(<<"error">>, Invalid))),
    BadConnection = json:decode(parvi_bridge:request(
        <<"{\"method\":\"connect\",\"connection_string\":\"invalid\"}">>)),
    ?assertEqual(<<"Invalid connection string. Copy a fresh one from the other instance.">>,
        maps:get(<<"error">>, BadConnection)),
    ?assert(is_process_alive(whereis(parvi_chat))).

correlated_snapshot_test_() ->
    {setup, fun() -> application:set_env(parvi, reception_desk_url, undefined), {ok, _} = parvi:start() end,
     fun(_) -> application:stop(parvi) end,
     fun() ->
        Reply = json:decode(parvi_bridge:request(
            <<"{\"method\":\"snapshot\",\"request_id\":\"ui-request-123\"}">>)),
        ?assertEqual(<<"ui-request-123">>, maps:get(<<"request_id">>, Reply)),
        ?assertEqual(null, maps:get(<<"connection_string">>, Reply)),
        #{<<"nodes">> := Rows, <<"edges">> := []} = maps:get(<<"network">>, Reply),
        ?assert(lists:any(fun(#{<<"id">> := Id}) -> Id =:= atom_to_binary(node()) end, Rows)),
        Failed = json:decode(parvi_bridge:request(
            <<"{\"method\":\"connect\",\"connection_string\":\"bad\",\"request_id\":\"join-1\"}">>)),
        ?assertEqual(<<"join-1">>, maps:get(<<"request_id">>, Failed)),
        ?assert(is_binary(maps:get(<<"error">>, Failed)))
     end}.

messaging() ->
    ok = parvi:subscribe(),
    ok = parvi:subscribe(),
    {ok, Message} = parvi:send(<<"Hei parvi!", 240, 159, 144, 166>>),
    receive {parvi_message, Message} -> ok after 1000 -> error(no_ui_event) end,
    receive {parvi_message, Message} -> error(duplicate_ui_event) after 0 -> ok end,
    ?assertEqual([Message], parvi:history()),
    ok = parvi:unsubscribe(),
    {ok, _} = parvi:send(<<"after unsubscribe">>),
    receive {parvi_message, _} -> error(unsubscribed_event) after 0 -> ok end.

validation_and_bounds() ->
    ?assertMatch({error, _}, parvi:send(<<>>)),
    ?assertMatch({error, _}, parvi:send("not a binary")),
    ?assertMatch({error, invalid_utf8}, parvi:send(<<255>>)),
    ?assertMatch({error, _}, parvi:send(binary:copy(<<"x">>, 4097))),
    {ok, _} = parvi:send(binary:copy(<<"x">>, 4096)),
    [parvi:send(integer_to_binary(I)) || I <- lists:seq(1, 205)],
    History = parvi:history(),
    ?assertEqual(200, length(History)),
    ?assertEqual(<<"6">>, maps:get(text, hd(History))),
    ?assertEqual(<<"205">>, maps:get(text, lists:last(History))),
    gen_server:cast(parvi_chat, {message, #{version => 999}}),
    ?assertEqual(History, parvi:history()).

restart() ->
    Old = whereis(parvi_chat),
    exit(Old, kill),
    New = await_restart(parvi_chat, Old, 100),
    ?assert(is_pid(New)),
    ?assertEqual([], parvi:history()),
    %% A pg restart must also restart the chat worker so membership is restored.
    OldPg = whereis(parvi_pg),
    exit(OldPg, kill),
    _ = await_restart(parvi_pg, OldPg, 100),
    _ = await_restart(parvi_chat, New, 100),
    ?assertEqual([node()], maps:get(chat_nodes, parvi:status())),
    ?assertMatch({ok, _}, parvi:send(<<"alive">>)).

await_restart(_Name, _Old, 0) -> error(restart_timeout);
await_restart(Name, Old, Attempts) ->
    case whereis(Name) of
        Pid when is_pid(Pid), Pid =/= Old -> Pid;
        _ -> timer:sleep(10), await_restart(Name, Old, Attempts - 1)
    end.
