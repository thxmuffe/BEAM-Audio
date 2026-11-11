-module(ba_buffees_tests).
-include_lib("eunit/include/eunit.hrl").

invitation_validation_test() ->
    {ok, _} = application:ensure_all_started(crypto),
    Id = binary:encode_hex(crypto:strong_rand_bytes(16)),
    Token = binary:encode_hex(crypto:strong_rand_bytes(16)),
    Link = ba_invitation:format(Id, Token),
    {ok, Parsed} = ba_invitation:parse(Link),
    ?assertEqual(Id, maps:get(buffee, Parsed)),
    ?assertEqual(Token, maps:get(token, Parsed)),
    [?assertEqual({error, invalid_invitation}, ba_invitation:parse(Bad)) || Bad <-
        [<<Link/binary, "&token=duplicate">>, <<Link/binary, "#fragment">>,
         <<"beamaudio://buffee/v1?buffee=bad&token=bad">>, <<"not an invitation">>,
         binary:copy(<<"x">>, 2049)]].

isolated_buffees_test_() ->
    {setup, fun() -> application:set_env(ba_core, reception_desk_url, undefined), {ok, _} = ba_runtime:start() end,
     fun(_) -> application:stop(ba_core) end,
     fun() ->
        {ok, A} = ba_buffees:create(<<"Music">>),
        {ok, B} = ba_buffees:create(<<"Another room">>),
        ok = ba_buffees:send(A, <<"Only A">>),
        ok = ba_buffees:send(B, <<"Only B">>),
        ?assertEqual([<<"Only A">>], texts(A)),
        ?assertEqual([<<"Only B">>], texts(B)),
        ?assertMatch({error, _}, ba_buffees:send(A, <<255>>)),
        ?assertMatch({error, _}, ba_buffees:remove_both(A, atom_to_binary(node()))),
        ok = ba_buffees:leave(A),
        ?assertNot(lists:any(fun(#{id := Id}) -> Id =:= A end, ba_buffees:snapshot())),
        ?assertEqual([<<"Only B">>], texts(B)),
        ?assertMatch({error, _}, ba_buffees:send(A, <<"No longer a member">>)),
        Reply = json:decode(ba_bridge:request(iolist_to_binary(json:encode(
            #{method => send_buffee, buffee_id => B, text => <<"Via bridge">>, request_id => <<"scoped">>})))),
        ?assertEqual(null, maps:get(<<"error">>, Reply)),
        ?assertEqual(<<"scoped">>, maps:get(<<"request_id">>, Reply)),
        ?assertEqual([<<"Only B">>, <<"Via bridge">>], texts(B))
     end}.

texts(Id) ->
    [Buffee] = [S || #{id := I} = S <- ba_buffees:snapshot(), I =:= Id],
    [maps:get(text, M) || M <- maps:get(messages, Buffee)].
