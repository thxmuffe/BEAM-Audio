-module(ba_contacts_tests).
-include_lib("eunit/include/eunit.hrl").

contacts_test_() ->
    {setup,
     fun() ->
         application:load(ba_core),
         Saved=[{K,os:getenv(K)} || K <- ["BA_STATE_DIR","BA_IDENTITY_SEED"]],
         Dir=filename:join("/tmp","ba_ephemeral_unit_"++integer_to_list(erlang:unique_integer([positive]))),
         os:putenv("BA_STATE_DIR",Dir),
         os:putenv("BA_IDENTITY_SEED","0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"),
         {ok,Pid}=ba_contacts:start_link(),unlink(Pid),
         {Pid,Saved,Dir}
     end,
     fun({Pid,Saved,Dir}) ->
         gen_server:stop(Pid,shutdown,5000),
         [case V of false -> os:unsetenv(K);_ -> os:putenv(K,V) end || {K,V} <- Saved],
         file:del_dir_r(Dir)
     end,
     [fun crud_and_validation/0,
      fun groups_and_resolve/0,
      fun contact_deletion_cleans_groups/0,
      fun automatic_collection_is_idempotent/0]}.

crud_and_validation() ->
    Id1 = binary:copy(<<"1">>, 64),
    Id2 = binary:copy(<<"2">>, 64),
    InvalidId = <<"short_id">>,
    ?assertEqual(#{contacts => #{}, groups => #{}, sessions => #{}}, ba_contacts:list()),
    ?assertEqual(ok, ba_contacts:put(Id1, <<"Alice">>)),
    ?assertEqual(ok, ba_contacts:put(Id2, <<"Bob">>)),
    #{contacts := Contacts} = ba_contacts:list(),
    ?assertEqual(<<"Alice">>, maps:get(Id1, Contacts)),
    ?assertEqual(<<"Bob">>, maps:get(Id2, Contacts)),
    ?assertMatch({error, _}, ba_contacts:put(InvalidId, <<"Invalid">>)),
    ?assertMatch({error, _}, ba_contacts:put(Id1, <<>>)).

groups_and_resolve() ->
    ?assertEqual(ok,ba_contacts:group(<<"Empty">>,[])),
    ?assertEqual([],maps:get(<<"Empty">>,maps:get(groups,ba_contacts:list()))),
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

%% Each Session seen is its own entry (not a group): its first name is kept,
%% Devices are only added, and a manual contact name wins over observed names.
automatic_collection_is_idempotent() ->
    A=binary:copy(<<"A">>,64),B=binary:copy(<<"B">>,64),Buffee=binary:copy(<<"1">>,32),
    ba_contacts:observe(Buffee,<<"10SWARNING">>,[A,A,B]),
    ba_contacts:observe_name(A,<<"MacBook Air | AABBCCDD">>),
    ba_contacts:observe(Buffee,<<"10SWARNING">>,[A,B]),
    #{contacts := Contacts,groups := Groups,sessions := Sessions}=ba_contacts:list(),
    ?assertEqual(<<"MacBook Air | AABBCCDD">>,maps:get(A,Contacts)),
    ?assertNot(maps:is_key(<<"10SWARNING">>,Groups)),
    #{name := <<"10SWARNING">>,devices := Devices}=maps:get(Buffee,Sessions),
    ?assertEqual(#{A => member,B => member},Devices),
    ?assertEqual(ok,ba_contacts:put(A,<<"My Mac">>)),
    ba_contacts:observe_name(A,<<"MacBook Air | NEW00001">>),
    ba_contacts:observe(Buffee,<<"Renamed gathering">>,[A]),
    #{contacts := Named,sessions := Updated}=ba_contacts:list(),
    ?assertEqual(<<"My Mac">>,maps:get(A,Named)),
    #{name := <<"10SWARNING">>,devices := Same}=maps:get(Buffee,Updated),
    ?assertEqual(Devices,Same).
