-module(parvi_audio_cluster_settings_tests).
-include_lib("eunit/include/eunit.hrl").

policy() -> #{<<"cluster">> => <<"test-cluster">>, <<"authority">> => atom_to_binary(node()),
    <<"revision">> => 1, <<"epoch">> => 1,
    <<"members">> => #{<<"actor">> => #{<<"node">> => atom_to_binary(node())}},invitations => #{}}.

non_member_cannot_set_sync_delay_test() ->
    S = policy(),
    ?assertEqual({reply,{error,not_a_member},S},parvi_cluster_authority:handle_call(
        {audio_sync_delay,<<"stranger">>,2000},{self(),make_ref()},S)).

cluster_setting_is_checkpointed_and_published_test() ->
    Dir = filename:join("/tmp","parvi-audio-setting-"++integer_to_list(erlang:unique_integer([positive]))),
    Saved = [{K,os:getenv(K)} || K <- ["PARVI_STATE_DIR","PARVI_IDENTITY_SEED"]],
    Parent = self(),
    Trust = spawn(fun() -> receive {'$gen_call',From,{install,Public}} ->
        Parent ! {installed,Public},gen_server:reply(From,ok) end end),
    true = register(parvi_cluster_trust,Trust),
    try
        os:putenv("PARVI_STATE_DIR",Dir),os:putenv("PARVI_IDENTITY_SEED","test-only"),
        {reply,ok,Next} = parvi_cluster_authority:handle_call(
            {audio_sync_delay,<<"actor">>,2400},{self(),make_ref()},policy()),
        ?assertEqual(2400,maps:get(<<"audio_sync_delay_ms">>,Next)),
        ?assertEqual(2,maps:get(<<"revision">>,Next)),
        ?assertEqual(1,maps:get(<<"epoch">>,Next)),
        ?assertEqual(Next,parvi_cluster_store:load(authority,undefined)),
        receive {installed,Public} -> ?assertEqual(2400,maps:get(<<"audio_sync_delay_ms">>,Public))
        after 1000 -> error(not_published) end
    after
        exit(Trust,kill),
        [case V of false -> os:unsetenv(K); _ -> os:putenv(K,V) end || {K,V} <- Saved],
        file:delete(filename:join(Dir,"authority.term")),file:del_dir(Dir)
    end.

invalid_sync_delay_is_rejected_test() ->
    [?assertMatch({error,_},parvi_cluster_trust:set_audio_sync_delay(N)) || N <- [-1,0,49,30001,1.2]].
