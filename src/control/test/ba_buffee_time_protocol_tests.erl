-module(ba_buffee_time_protocol_tests).
-include_lib("eunit/include/eunit.hrl").
canonical_full_precision_nanoseconds_test() ->
    [begin B = ba_buffee_time_protocol:encode(N),?assertEqual(N,ba_buffee_time_protocol:integer(B)) end
        || N <- [-576460751123456789,1793820000123456789,9223372036854775807]],
    [?assertException(error,_,ba_buffee_time_protocol:integer(B)) || B <-
        [<<"+1">>,<<"01">>,<<"-0">>,<<"9223372036854775808">>,<<"1.1">>]].
current_offset_revision_must_not_roll_back_or_conflict_test() ->
    P = #{<<"revision">> => 3,<<"offset_ms">> => 250},
    ?assertEqual(P,ba_buffee_time_protocol:accept(P,P)),
    ?assertException(error,_,ba_buffee_time_protocol:accept(P#{<<"revision">> := 2},P)),
    ?assertException(error,conflicting_revision,ba_buffee_time_protocol:accept(P#{<<"offset_ms">> := 500},P)),
    ?assertEqual(4,maps:get(<<"revision">>,ba_buffee_time_protocol:accept(P#{<<"revision">> := 4},P))).
strict_time_shapes_and_permissions_test() ->
    ?assertEqual(time_read,ba_buffee_time_protocol:permission(<<"sample.request">>)),
    ?assertEqual(offset_write,ba_buffee_time_protocol:permission(<<"offset.set">>)),
    ?assertException(error,_,ba_buffee_time_protocol:validate(#{<<"kind">> => <<"offset.set">>,<<"revision">> => 1,<<"offset_ms">> => 0})),
    ?assertException(error,_,ba_buffee_time_protocol:validate(#{<<"kind">> => <<"sample.request">>,<<"t1">> => 123})),
    ?assertException(error,_,ba_buffee_time_protocol:validate(#{<<"kind">> => <<"offset.get">>,<<"rpc">> => <<"anything">>})).
