-module(ba_session_time_protocol_tests).
-include_lib("eunit/include/eunit.hrl").
canonical_full_precision_nanoseconds_test() ->
    [begin B = ba_session_time_protocol:encode(N),?assertEqual(N,ba_session_time_protocol:integer(B)) end
        || N <- [-576460751123456789,1793820000123456789,9223372036854775807]],
    [?assertException(error,_,ba_session_time_protocol:integer(B)) || B <-
        [<<"+1">>,<<"01">>,<<"-0">>,<<"9223372036854775808">>,<<"1.1">>]].
current_offset_revision_must_not_roll_back_or_conflict_test() ->
    P = #{<<"revision">> => 3,<<"offset_ms">> => 250},
    ?assertEqual(P,ba_session_time_protocol:accept(P,P)),
    ?assertException(error,_,ba_session_time_protocol:accept(P#{<<"revision">> := 2},P)),
    ?assertException(error,conflicting_revision,ba_session_time_protocol:accept(P#{<<"offset_ms">> := 500},P)),
    ?assertEqual(4,maps:get(<<"revision">>,ba_session_time_protocol:accept(P#{<<"revision">> := 4},P))).
strict_time_shapes_and_permissions_test() ->
    ?assertEqual(time_read,ba_session_time_protocol:permission(<<"sample.request">>)),
    ?assertEqual(offset_write,ba_session_time_protocol:permission(<<"offset.set">>)),
    ?assertException(error,_,ba_session_time_protocol:validate(#{<<"kind">> => <<"offset.set">>,<<"revision">> => 1,<<"offset_ms">> => 0})),
    ?assertException(error,_,ba_session_time_protocol:validate(#{<<"kind">> => <<"sample.request">>,<<"t1">> => 123})),
    ?assertException(error,_,ba_session_time_protocol:validate(#{<<"kind">> => <<"offset.get">>,<<"rpc">> => <<"anything">>})).

automatic_policy_and_minimum_request_are_revisioned_test() ->
    Old=#{<<"revision">> => 1,<<"offset_ms">> => 300},
    Auto=Old#{<<"revision">> := 2,<<"automatic">> => true},
    ?assertEqual(ok,ba_session_time_protocol:validate(Auto#{<<"kind">> => <<"offset.state">>})),
    ?assertEqual(Auto,ba_session_time_protocol:accept(Auto,Auto)),
    ?assertException(error,conflicting_revision,ba_session_time_protocol:accept(maps:remove(<<"automatic">>,Auto),Auto)),
    ?assertException(error,_,ba_session_time_protocol:validate(Auto#{<<"kind">> => <<"offset.set">>,<<"automatic">> := <<"yes">>})),
    ?assertEqual(time_read,ba_session_time_protocol:permission(<<"offset.required">>)),
    ?assertEqual(ok,ba_session_time_protocol:validate(#{<<"kind">> => <<"offset.required">>,<<"revision">> => 2,<<"offset_ms">> => 450})).
