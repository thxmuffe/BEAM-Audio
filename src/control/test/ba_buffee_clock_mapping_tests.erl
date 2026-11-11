-module(ba_buffee_clock_mapping_tests).
-include_lib("eunit/include/eunit.hrl").

slew_and_inverse_test() ->
    [check_slew(Delta) || Delta <- [-10000000, 10000000]], ok.

check_slew(Delta) ->
    Base = ba_buffee_clock_mapping:new(-2000000000, 1700000000000000000),
    M = ba_buffee_clock_mapping:correct(Base, -1000000000,
        1700000000000000000 + Delta, 500),
    Times = [-1000000100, -1000000000, -999999999, 0, 1000000000,
             5000000000, 19000000000, 20000000000],
    UTC = [ba_buffee_clock_mapping:from_monotonic(M,T) || T <- Times],
    ?assertEqual(UTC,lists:sort(UTC)),
    [?assert(abs(T-ba_buffee_clock_mapping:to_monotonic(M,U)) =< 1) || {T,U} <- lists:zip(Times,UTC)],
    ?assertEqual(0,ba_buffee_clock_mapping:remaining(M,20000000000)),
    ?assertEqual(ba_buffee_clock_mapping:from_monotonic(Base,-1000000000),hd(tl(UTC))).

retarget_preserves_continuity_test() ->
    A = ba_buffee_clock_mapping:correct(ba_buffee_clock_mapping:new(0,1000000),0,-1000000,500),
    T = 1000000000,
    B = ba_buffee_clock_mapping:correct(A,T,2000000,500),
    ?assertEqual(ba_buffee_clock_mapping:from_monotonic(A,T),ba_buffee_clock_mapping:from_monotonic(B,T)),
    ?assert(ba_buffee_clock_mapping:from_monotonic(B,T+1000) >= ba_buffee_clock_mapping:from_monotonic(B,T)).

inverse_chooses_earliest_deadline_test() ->
    [begin
        M = ba_buffee_clock_mapping:correct(ba_buffee_clock_mapping:new(0,0),0,Delta,PPM),
        [begin
            T = ba_buffee_clock_mapping:to_monotonic(M,U),
            ?assert(ba_buffee_clock_mapping:from_monotonic(M,T) >= U),
            ?assert(ba_buffee_clock_mapping:from_monotonic(M,T-1) < U)
         end || U <- [-1,0,1,2,999,1000000,2000000]]
     end || Delta <- [-1000000,1000000], PPM <- [500,999999]], ok.
