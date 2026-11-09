-module(parvi_audio_subscription_intent_tests).
-include_lib("eunit/include/eunit.hrl").
-export([with_store/1,intent/1]).
intent(Key) -> parvi_audio_subscription_intent:new(binary:copy(<<"A">>,32),binary:copy(<<"B">>,64),
    #{name => Key,source_key => Key},channel).
source_restart_keeps_identity_test() ->
    I = intent(<<"music">>),O = #{source_key => <<"music">>,profiles => #{channel => #{}}},
    ?assert(parvi_audio_subscription_intent:matches(I,binary:copy(<<"B">>,64),O)),
    ?assertNot(parvi_audio_subscription_intent:matches(I,binary:copy(<<"C">>,64),O)),
    ?assertNot(parvi_audio_subscription_intent:matches(I,binary:copy(<<"B">>,64),O#{source_key := <<"mic">>})).
collection_persistence_and_scoped_unsubscribe_test() -> with_store(fun() ->
    A = intent(<<"music">>),B = intent(<<"mic">>),X = maps:get(id,A),Y = maps:get(id,B),
    Items = #{X => A,Y => B#{playing := true}},
    ok = parvi_audio_subscription_intent:save(Items),?assertEqual(Items,parvi_audio_subscription_intent:load()),
    ok = parvi_audio_subscription_intent:save(maps:remove(X,Items)),
    ?assertEqual(#{Y => B#{playing := true}},parvi_audio_subscription_intent:load()),
    ?assertException(error,_,parvi_audio_subscription_intent:save(#{X => A#{session => self()}}))
end).
old_single_subscription_is_not_imported_test() -> with_store(fun() ->
    ok = parvi_cluster_store:save(audio_subscription,#{node => <<"old-node">>,playing => true}),
    ?assertEqual(#{},parvi_audio_subscription_intent:load())
end).
fresh_clock_required_after_resume_test() ->
    Clock = #{state => synchronized,filter_ready => true,last_sync => 100,age_ns => 0},
    ?assertNot(parvi_audio_subscription_intent:clock_ready(Clock,101)),
    ?assert(parvi_audio_subscription_intent:clock_ready(Clock#{last_sync := 102},101)),
    ?assertNot(parvi_audio_subscription_intent:clock_ready(Clock#{age_ns := 11000000000},undefined)),
    ?assertNot(parvi_audio_subscription_intent:clock_ready(Clock#{age_ns := -1},undefined)),
    ?assert(parvi_audio_subscription_intent:clock_ready(#{state => synchronized,role => master,filtered_utc_time => 1000,last_sync => 102},101)).
with_store(Fun) ->
    Dir = filename:join("/tmp","parvi-subscriptions-"++integer_to_list(erlang:unique_integer([positive]))),
    Saved = [{K,os:getenv(K)} || K <- ["PARVI_STATE_DIR","PARVI_IDENTITY_SEED"]],
    try os:putenv("PARVI_STATE_DIR",Dir),os:putenv("PARVI_IDENTITY_SEED","test-only"),Fun()
    after
        [case V of false -> os:unsetenv(K);_ -> os:putenv(K,V) end || {K,V} <- Saved],
        [file:delete(filename:join(Dir,F)) || F <- ["audio_subscription.term","audio_subscriptions.term"]],file:del_dir(Dir)
    end.
