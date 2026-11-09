-module(ba_audio_cluster_settings_tests).
-include_lib("eunit/include/eunit.hrl").

policy() -> #{<<"cluster">> => <<"test-cluster">>, <<"authority">> => atom_to_binary(node()),
    <<"revision">> => 1, <<"epoch">> => 1,
    <<"members">> => #{<<"actor">> => #{<<"node">> => atom_to_binary(node())}},invitations => #{}}.

non_member_cannot_set_sync_delay_test() ->
    S = policy(),
    ?assertEqual({reply,{error,not_a_member},S},ba_legacy_cluster_authority:handle_call(
        {audio_sync_delay,<<"stranger">>,2000},{self(),make_ref()},S)).

cluster_setting_is_checkpointed_and_published_test() ->
    Dir = filename:join("/tmp","ba_core-audio-setting-"++integer_to_list(erlang:unique_integer([positive]))),
    Saved = [{K,os:getenv(K)} || K <- ["BA_STATE_DIR","BA_IDENTITY_SEED"]],
    Parent = self(),
    Trust = spawn(fun Loop() -> receive {'$gen_call',From,{install,Public}} ->
        Parent ! {installed,Public},gen_server:reply(From,ok),Loop() end end),
    true = register(ba_legacy_cluster_trust,Trust),
    try
        os:putenv("BA_STATE_DIR",Dir),os:putenv("BA_IDENTITY_SEED","test-only"),
        {reply,ok,Minimum} = ba_legacy_cluster_authority:handle_call(
            {audio_sync_delay,<<"actor">>,5},{self(),make_ref()},policy()),
        ?assertEqual(5,maps:get(<<"audio_sync_delay_ms">>,Minimum)),
        receive {installed,AtMinimum} -> ?assertEqual(5,maps:get(<<"audio_sync_delay_ms">>,AtMinimum))
        after 1000 -> error(minimum_not_published) end,
        {reply,ok,Next} = ba_legacy_cluster_authority:handle_call(
            {audio_sync_delay,<<"actor">>,2400},{self(),make_ref()},Minimum),
        ?assertEqual(2400,maps:get(<<"audio_sync_delay_ms">>,Next)),
        ?assertEqual(3,maps:get(<<"revision">>,Next)),
        ?assertEqual(1,maps:get(<<"epoch">>,Next)),
        ?assertEqual(Next,ba_device_store:load(authority,undefined)),
        receive {installed,Public} -> ?assertEqual(2400,maps:get(<<"audio_sync_delay_ms">>,Public))
        after 1000 -> error(not_published) end
    after
        exit(Trust,kill),
        [case V of false -> os:unsetenv(K); _ -> os:putenv(K,V) end || {K,V} <- Saved],
        file:delete(filename:join(Dir,"authority.term")),file:del_dir(Dir)
    end.

invalid_sync_delay_is_rejected_test() ->
    [?assertMatch({error,_},ba_legacy_cluster_trust:set_audio_sync_delay(N)) || N <- [-1,0,4,30001,1.2]].
