-module(ba_response_time_tests).
-include_lib("eunit/include/eunit.hrl").

session_weighted_average_counts_each_note_once_test() ->
    with_state(fun(S) ->
        {noreply,S1}=measurement(<<"first">>,1,30000000,S),
        {noreply,S2}=measurement(<<"second">>,3,210000000,S1),
        ?assertEqual({noreply,S2},measurement(<<"first">>,1,30000000,S2)),
        ?assertMatch(#{measured_ms := 60,measurement_count := 4,measurement_sum_ns := 240000000},
            ba_response_time:view())
    end).

playback_start_resets_cadence_and_retains_the_measurements_test() ->
    with_state(fun(S) ->
        {noreply,S1}=measurement(<<"first">>,2,80000000,S),
        {noreply,S2}=playback(2,true,true,S1),
        ?assertMatch(#{samples := 0,next := undefined},S2),
        ?assertMatch(#{measured_ms := 40,measurement_count := 2},ba_response_time:view()),
        ?assertMatch(#{<<"peer">> := #{playing := true}},ba_response_time:playback_states()),
        {noreply,S3}=playback(3,false,false,S2),
        ?assertEqual({noreply,S3},playback(2,true,true,S3)),
        ?assertMatch(#{<<"peer">> := #{playing := false}},ba_response_time:playback_states())
    end).

measurement(Id,Count,Sum,S) ->
    ba_response_time:handle_cast({reported,Id,#{<<"count">> => Count,<<"sum_ns">> => Sum,
        <<"at">> => erlang:system_time(second)}},S).

playback(Revision,Playing,Started,S) ->
    ba_response_time:handle_cast({remote_playback,<<"peer">>,#{<<"playing">> => Playing,<<"failed">> => false,
        <<"started">> => Started,<<"revision">> => Revision}},S).

with_state(F) ->
    Table=ets:new(ba_response_time,[named_table]),
    try F(#{reports => #{},samples => 0,playback_states => #{},next => 1234})
    after ets:delete(Table) end.
