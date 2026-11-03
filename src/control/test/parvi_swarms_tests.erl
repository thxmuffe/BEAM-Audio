-module(parvi_swarms_tests).
-include_lib("eunit/include/eunit.hrl").

invitation_validation_test() ->
    {ok, _} = application:ensure_all_started(crypto),
    Id = binary:encode_hex(crypto:strong_rand_bytes(16)),
    Token = binary:encode_hex(crypto:strong_rand_bytes(16)),
    Link = parvi_invitation:format(Id, Token),
    {ok, Parsed} = parvi_invitation:parse(Link),
    ?assertEqual(Id, maps:get(swarm, Parsed)),
    ?assertEqual(Token, maps:get(token, Parsed)),
    [?assertEqual({error, invalid_invitation}, parvi_invitation:parse(Bad)) || Bad <-
        [<<Link/binary, "&token=duplicate">>, <<Link/binary, "#fragment">>,
         <<"parvi://swarm/v1?swarm=bad&token=bad">>, <<"not an invitation">>,
         binary:copy(<<"x">>, 2049)]].

isolated_swarms_test_() ->
    {setup, fun() -> application:set_env(parvi, reception_desk_url, undefined), {ok, _} = parvi:start() end,
     fun(_) -> application:stop(parvi) end,
     fun() ->
        {ok, A} = parvi_swarms:create(<<"Music">>),
        {ok, B} = parvi_swarms:create(<<"Another room">>),
        ok = parvi_swarms:send(A, <<"Only A">>),
        ok = parvi_swarms:send(B, <<"Only B">>),
        ?assertEqual([<<"Only A">>], texts(A)),
        ?assertEqual([<<"Only B">>], texts(B)),
        ?assertMatch({error, _}, parvi_swarms:send(A, <<255>>)),
        ?assertMatch({error, _}, parvi_swarms:remove_both(A, atom_to_binary(node()))),
        ok = parvi_swarms:leave(A),
        ?assertNot(lists:any(fun(#{id := Id}) -> Id =:= A end, parvi_swarms:snapshot())),
        ?assertEqual([<<"Only B">>], texts(B)),
        ?assertMatch({error, _}, parvi_swarms:send(A, <<"No longer a member">>)),
        Reply = json:decode(parvi_bridge:request(iolist_to_binary(json:encode(
            #{method => send_swarm, swarm_id => B, text => <<"Via bridge">>, request_id => <<"scoped">>})))),
        ?assertEqual(null, maps:get(<<"error">>, Reply)),
        ?assertEqual(<<"scoped">>, maps:get(<<"request_id">>, Reply)),
        ?assertEqual([<<"Only B">>, <<"Via bridge">>], texts(B))
     end}.

texts(Id) ->
    [Swarm] = [S || #{id := I} = S <- parvi_swarms:snapshot(), I =:= Id],
    [maps:get(text, M) || M <- maps:get(messages, Swarm)].
