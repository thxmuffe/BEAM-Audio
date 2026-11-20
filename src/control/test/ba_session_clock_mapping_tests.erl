-module(ba_session_clock_mapping_tests).
-include_lib("eunit/include/eunit.hrl").

slew_is_monotonic_test() ->
    [check_slew(Delta) || Delta <- [-10000000, 10000000]], ok.

check_slew(Delta) ->
    Base = ba_session_clock_mapping:new(-2000000000, 1700000000000000000),
    M = ba_session_clock_mapping:correct(Base, -1000000000,
        1700000000000000000 + Delta, 500),
    Times = [-1000000100, -1000000000, -999999999, 0, 1000000000,
             5000000000, 19000000000, 20000000000],
    UTC = [ba_session_clock_mapping:from_monotonic(M,T) || T <- Times],
    ?assertEqual(UTC,lists:sort(UTC)),
    ?assertEqual(0,ba_session_clock_mapping:remaining(M,20000000000)),
    ?assertEqual(ba_session_clock_mapping:from_monotonic(Base,-1000000000),hd(tl(UTC))).

retarget_preserves_continuity_test() ->
    A = ba_session_clock_mapping:correct(ba_session_clock_mapping:new(0,1000000),0,-1000000,500),
    T = 1000000000,
    B = ba_session_clock_mapping:correct(A,T,2000000,500),
    ?assertEqual(ba_session_clock_mapping:from_monotonic(A,T),ba_session_clock_mapping:from_monotonic(B,T)),
    ?assert(ba_session_clock_mapping:from_monotonic(B,T+1000) >= ba_session_clock_mapping:from_monotonic(B,T)).
