-module(ba_contacts_tests).
-include_lib("eunit/include/eunit.hrl").

contacts_test_() ->
    {setup,
     fun() ->
         application:load(ba_core),
         application:set_env(ba_core, runtime_profile, swarm_control),
         {ok, _} = ba_contacts:start_link()
     end,
     fun(_) ->
         try gen_server:stop(ba_contacts) catch _:_ -> ok end,
         application:unset_env(ba_core, runtime_profile)
     end,
     [fun crud_and_validation/0,
      fun groups_and_resolve/0,
      fun contact_deletion_cleans_groups/0]}.

crud_and_validation() ->
    Id1 = binary:copy(<<"1">>, 64),
    Id2 = binary:copy(<<"2">>, 64),
    InvalidId = <<"short_id">>,
    ?assertEqual(#{contacts => #{}, groups => #{}}, ba_contacts:list()),
    ?assertEqual(ok, ba_contacts:put(Id1, <<"Alice">>)),
    ?assertEqual(ok, ba_contacts:put(Id2, <<"Bob">>)),
    #{contacts := Contacts} = ba_contacts:list(),
    ?assertEqual(<<"Alice">>, maps:get(Id1, Contacts)),
    ?assertEqual(<<"Bob">>, maps:get(Id2, Contacts)),
    ?assertMatch({error, _}, ba_contacts:put(InvalidId, <<"Invalid">>)),
    ?assertMatch({error, _}, ba_contacts:put(Id1, <<>>)).

groups_and_resolve() ->
    Id1 = binary:copy(<<"1">>, 64),
    Id2 = binary:copy(<<"2">>, 64),
    UnknownId = binary:copy(<<"f">>, 64),
    ?assertEqual(ok, ba_contacts:group(<<"Friends">>, [Id1, Id2])),
    ?assertMatch({error, _}, ba_contacts:group(<<"Invalid">>, [UnknownId])),
    ?assertEqual({ok, [Id1, Id2]}, ba_contacts:resolve({group, <<"Friends">>})),
    ?assertEqual({ok, [Id1]}, ba_contacts:resolve([Id1])),
    ?assertEqual({error, invalid_contact_selection}, ba_contacts:resolve({group, <<"Unknown">>})),
    ?assertEqual({error, invalid_contact_selection}, ba_contacts:resolve([])).

contact_deletion_cleans_groups() ->
    Id1 = binary:copy(<<"1">>, 64),
    Id2 = binary:copy(<<"2">>, 64),
    ?assertEqual(ok, ba_contacts:delete(Id1)),
    #{contacts := Contacts, groups := Groups} = ba_contacts:list(),
    ?assertNot(maps:is_key(Id1, Contacts)),
    ?assertEqual([Id2], maps:get(<<"Friends">>, Groups)),
    ?assertEqual(ok, ba_contacts:delete_group(<<"Friends">>)),
    ?assertNot(maps:is_key(<<"Friends">>, maps:get(groups, ba_contacts:list()))).
