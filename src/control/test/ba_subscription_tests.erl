-module(ba_subscription_tests).
-include_lib("eunit/include/eunit.hrl").
-export([with_store/1,intent/1]).
intent(Key) -> ba_subscription:new(binary:copy(<<"A">>,32),binary:copy(<<"B">>,64),
    #{name => Key,source_key => Key},channel).
source_restart_keeps_identity_test() ->
    I = intent(<<"music">>),O = #{source_key => <<"music">>,profiles => #{channel => #{}}},
    ?assert(ba_subscription:matches(I,binary:copy(<<"B">>,64),O)),
    ?assertNot(ba_subscription:matches(I,binary:copy(<<"C">>,64),O)),
    ?assertNot(ba_subscription:matches(I,binary:copy(<<"B">>,64),O#{source_key := <<"mic">>})).
collection_persistence_and_scoped_unsubscribe_test() -> with_store(fun() ->
    A = intent(<<"music">>),B = intent(<<"mic">>),X = maps:get(id,A),Y = maps:get(id,B),
    Items = #{X => A,Y => B#{playing := true}},
    ok = ba_subscription:save(Items),?assertEqual(Items,ba_subscription:load()),
    ok = ba_subscription:save(maps:remove(X,Items)),
    ?assertEqual(#{Y => B#{playing := true}},ba_subscription:load()),
    ?assertException(error,_,ba_subscription:save(#{X => A#{session => self()}}))
end).
old_single_subscription_is_not_imported_test() -> with_store(fun() ->
    ok = ba_device_store:save(audio_subscription,#{node => <<"old-node">>,playing => true}),
    ?assertEqual(#{},ba_subscription:load())
end).
fresh_clock_required_after_resume_test() ->
    Clock = #{state => synchronized,filter_ready => true,last_sync => 100,age_ns => 0},
    ?assertNot(ba_subscription:clock_ready(Clock,101)),
    ?assert(ba_subscription:clock_ready(Clock#{last_sync := 102},101)),
    ?assertNot(ba_subscription:clock_ready(Clock#{age_ns := 11000000000},undefined)),
    ?assertNot(ba_subscription:clock_ready(Clock#{age_ns := -1},undefined)),
    ?assert(ba_subscription:clock_ready(#{state => synchronized,role => master,filtered_utc_time => 1000,last_sync => 102},101)).
with_store(Fun) ->
    Dir = filename:join("/tmp","ba_core-subscriptions-"++integer_to_list(erlang:unique_integer([positive]))),
    Saved = [{K,os:getenv(K)} || K <- ["BA_STATE_DIR","BA_IDENTITY_SEED"]],
    try os:putenv("BA_STATE_DIR",Dir),os:putenv("BA_IDENTITY_SEED","test-only"),Fun()
    after
        [case V of false -> os:unsetenv(K);_ -> os:putenv(K,V) end || {K,V} <- Saved],
        [file:delete(filename:join(Dir,F)) || F <- ["audio_subscription.term","audio_subscriptions.term"]],file:del_dir(Dir)
    end.
