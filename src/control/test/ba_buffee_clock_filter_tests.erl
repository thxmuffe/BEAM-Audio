-module(ba_buffee_clock_filter_tests).
-include_lib("eunit/include/eunit.hrl").

window(Offsets) -> lists:foldl(fun(Offset,F) ->
    ba_buffee_clock_filter:add(#{offset_ns => Offset},F)
end,ba_buffee_clock_filter:new(20),Offsets).

twenty_samples_required_test() ->
    F = window(lists:seq(1,19)),
    ?assertEqual({error,warming_up},ba_buffee_clock_filter:estimate(F)),
    ?assertEqual(19,ba_buffee_clock_filter:count(F)),
    Full = ba_buffee_clock_filter:add(#{offset_ns => 20},F),
    ?assertEqual({ok,10},ba_buffee_clock_filter:estimate(Full)).

isolated_spikes_do_not_move_the_median_test() ->
    F = window([100000000 | lists:duplicate(18,1000)] ++ [-100000000]),
    ?assertEqual({ok,1000},ba_buffee_clock_filter:estimate(F)).

old_samples_leave_the_bounded_window_test() ->
    F = window(lists:duplicate(20,-1000) ++ lists:duplicate(20,3000)),
    ?assertEqual(20,ba_buffee_clock_filter:count(F)),
    ?assertEqual({ok,3000},ba_buffee_clock_filter:estimate(F)).

two_ms_is_a_strict_deadband_test() ->
    M = ba_buffee_clock_mapping:new(0,1000000000),
    [begin
        {Same,_,Adjusted} = ba_buffee_clock_sync:correct(M,100,1000000000+Error,2000000,500),
        ?assertEqual(M,Same), ?assertNot(Adjusted)
     end || Error <- [-2000000,0,2000000]],
    [begin
        {Next,_,true} = ba_buffee_clock_sync:correct(M,100,1000000000+Error,2000000,500),
        ?assertEqual(ba_buffee_clock_mapping:from_monotonic(M,100),
                     ba_buffee_clock_mapping:from_monotonic(Next,100)),
        ?assert(ba_buffee_clock_mapping:from_monotonic(Next,101) >=
                ba_buffee_clock_mapping:from_monotonic(Next,100))
     end || Error <- [-2000001,2000001]].

four_timestamps_remove_symmetric_delay_and_service_time_test() ->
    %% Offset 500, each network leg 200, remote service 50.
    ?assertEqual({ok,#{offset_ns => 500,sampled_at => 1450,round_trip_ns => 400}},
        ba_buffee_clock_sync:measure(1000,1700,1750,1450)),
    ?assertEqual({error,invalid_peer_timestamps},ba_buffee_clock_sync:measure(0,100,200,50)),
    ?assertEqual({error,invalid_peer_timestamps},ba_buffee_clock_sync:measure(0,200,100,500)).
