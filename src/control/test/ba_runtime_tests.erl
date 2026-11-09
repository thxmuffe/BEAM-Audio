-module(ba_runtime_tests).
-include_lib("eunit/include/eunit.hrl").

connection_string_roundtrip_test() ->
    Node = <<"ba_windows_123@127.0.0.1">>,
    Cookie = <<"secret+/=&?%">>,
    String = ba_legacy_connection:format(Node, Cookie),
    ?assertEqual({ok, #{node => Node, cookie => Cookie}}, ba_legacy_connection:parse(String)),
    ?assertEqual(ba_legacy_connection:parse(String), ba_legacy_connection:parse(<<" \n", String/binary, "\r\n">>)).

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
    [?assertEqual({error, invalid_connection_string}, ba_legacy_connection:parse(Input)) || Input <- Bad].

chat_test_() ->
    {setup, fun() -> application:set_env(ba_core, reception_desk_url, undefined), {ok, _} = ba_runtime:start() end,
     fun(_) -> application:stop(ba_core) end,
     [fun messaging/0, fun validation_and_bounds/0, fun bridge_request/0, fun restart/0]}.

bridge_request() ->
    Reply = json:decode(ba_bridge:request(<<"{\"method\":\"send\",\"text\":\"native host\"}">>)),
    ?assertEqual(null, maps:get(<<"error">>, Reply)),
    ?assertEqual(<<"native host">>, maps:get(<<"text">>, lists:last(maps:get(<<"messages">>, Reply)))),
    Invalid = json:decode(ba_bridge:request(<<"not json">>)),
    ?assert(is_binary(maps:get(<<"error">>, Invalid))),
    BadConnection = json:decode(ba_bridge:request(
        <<"{\"method\":\"connect\",\"connection_string\":\"invalid\"}">>)),
    ?assertEqual(<<"Invalid connection string. Copy a fresh one from the other instance.">>,
        maps:get(<<"error">>, BadConnection)),
    ?assert(is_process_alive(whereis(ba_chat))).

correlated_snapshot_test_() ->
    {setup, fun() -> application:set_env(ba_core, reception_desk_url, undefined), {ok, _} = ba_runtime:start() end,
     fun(_) -> application:stop(ba_core) end,
     fun() ->
        Reply = json:decode(ba_bridge:request(
            <<"{\"method\":\"snapshot\",\"request_id\":\"ui-request-123\"}">>)),
        ?assertEqual(<<"ui-request-123">>, maps:get(<<"request_id">>, Reply)),
        ?assertEqual(null, maps:get(<<"connection_string">>, Reply)),
        #{<<"nodes">> := Rows, <<"edges">> := []} = maps:get(<<"network">>, Reply),
        ?assert(lists:any(fun(#{<<"id">> := Id}) -> Id =:= atom_to_binary(node()) end, Rows)),
        Failed = json:decode(ba_bridge:request(
            <<"{\"method\":\"connect\",\"connection_string\":\"bad\",\"request_id\":\"join-1\"}">>)),
        ?assertEqual(<<"join-1">>, maps:get(<<"request_id">>, Failed)),
        ?assert(is_binary(maps:get(<<"error">>, Failed)))
     end}.

messaging() ->
    ok = ba_runtime:subscribe(),
    ok = ba_runtime:subscribe(),
    {ok, Message} = ba_runtime:send(<<"Hei ba_core!", 240, 159, 144, 166>>),
    receive {ba_message, Message} -> ok after 1000 -> error(no_ui_event) end,
    receive {ba_message, Message} -> error(duplicate_ui_event) after 0 -> ok end,
    ?assertEqual([Message], ba_runtime:history()),
    ok = ba_runtime:unsubscribe(),
    {ok, _} = ba_runtime:send(<<"after unsubscribe">>),
    receive {ba_message, _} -> error(unsubscribed_event) after 0 -> ok end.

validation_and_bounds() ->
    ?assertMatch({error, _}, ba_runtime:send(<<>>)),
    ?assertMatch({error, _}, ba_runtime:send("not a binary")),
    ?assertMatch({error, invalid_utf8}, ba_runtime:send(<<255>>)),
    ?assertMatch({error, _}, ba_runtime:send(binary:copy(<<"x">>, 4097))),
    {ok, _} = ba_runtime:send(binary:copy(<<"x">>, 4096)),
    [ba_runtime:send(integer_to_binary(I)) || I <- lists:seq(1, 205)],
    History = ba_runtime:history(),
    ?assertEqual(200, length(History)),
    ?assertEqual(<<"6">>, maps:get(text, hd(History))),
    ?assertEqual(<<"205">>, maps:get(text, lists:last(History))),
    gen_server:cast(ba_chat, {message, #{version => 999}}),
    ?assertEqual(History, ba_runtime:history()).

restart() ->
    Old = whereis(ba_chat),
    exit(Old, kill),
    New = await_restart(ba_chat, Old, 100),
    ?assert(is_pid(New)),
    ?assertEqual([], ba_runtime:history()),
    %% A pg restart must also restart the chat worker so membership is restored.
    OldPg = whereis(ba_pg),
    exit(OldPg, kill),
    _ = await_restart(ba_pg, OldPg, 100),
    _ = await_restart(ba_chat, New, 100),
    ?assertEqual([node()], maps:get(chat_nodes, ba_runtime:status())),
    ?assertMatch({ok, _}, ba_runtime:send(<<"alive">>)).

await_restart(_Name, _Old, 0) -> error(restart_timeout);
await_restart(Name, Old, Attempts) ->
    case whereis(Name) of
        Pid when is_pid(Pid), Pid =/= Old -> Pid;
        _ -> timer:sleep(10), await_restart(Name, Old, Attempts - 1)
    end.
