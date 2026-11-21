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
        ?assertMatch(#{report_cadence := #{observations := 0}},S2),
        ?assertMatch(#{measured_ms := 40,measurement_count := 2},ba_response_time:view()),
        ?assertMatch(#{<<"peer">> := #{playing := true}},ba_response_time:playback_states()),
        {noreply,S3}=playback(3,false,false,S2),
        ?assertEqual({noreply,S3},playback(2,true,true,S3)),
        ?assertMatch(#{<<"peer">> := #{playing := false}},ba_response_time:playback_states())
    end).

publishing_adjusts_both_directions_from_the_exact_mean_test() ->
    with_membership(fun() -> with_state(fun(S) ->
        %% 45 ms * 2.5 = 112.5 ms, rounded once for the integer setting.
        {noreply,S1}=measurement(<<"first">>,2,90000000,S),
        {noreply,S2}=activity([<<"microphone">>],S1),
        ?assertNot(ba_cadence:due(maps:get(adjust_cadence,S2),erlang:monotonic_time(millisecond))),
        {noreply,S3}=tick((adjustment_due(S2))#{offset_ms := 150}),
        expect_response(113),
        {noreply,_}=tick((adjustment_due(S3))#{offset_ms := 50}),
        expect_response(113)
    end) end).

new_input_or_playback_resets_the_adjustment_cadence_test() ->
    with_membership(fun() -> with_state(fun(S) ->
        {noreply,S1}=measurement(<<"first">>,1,40000000,S),
        {noreply,S2}=activity([<<"capture">>],S1),
        {noreply,Mature}=tick((adjustment_due(S2))#{offset_ms := 100}),
        ?assertMatch(#{adjust_cadence := #{observations := 1}},Mature),
        {noreply,Same}=activity([<<"capture">>],Mature),
        ?assertEqual(Mature,Same),
        {noreply,Reset}=activity([<<"capture">>,<<"microphone">>],Same),
        ?assertMatch(#{adjust_cadence := #{observations := 0}},Reset),
        {noreply,PlaybackReset}=playback(1,true,true,Mature),
        ?assertMatch(#{adjust_cadence := #{observations := 0}},PlaybackReset),
        expect_no_response()
    end) end).

adjustment_requires_broadcasting_readiness_fresh_samples_and_due_time_test() ->
    with_membership(fun() -> with_state(fun(S) ->
        {noreply,S1}=measurement(<<"first">>,1,45000000,S),
        {noreply,Publishing}=activity([<<"capture">>],S1),
        Base=adjustment_due(Publishing),
        [tick(State) || State <- [
            Base#{published := []},Base#{ready := false},Base#{reports := #{}},
            Publishing,Base#{automatic := false},
            Base#{reports := #{<<"old">> => {1,45000000,erlang:system_time(second)-121}}}]],
        %% Pausing/stopping the last source cancels automatic changes.
        {noreply,Stopped}=activity([],Base),
        tick(Stopped),
        expect_no_response()
    end) end).

adjustment_rounds_once_and_respects_the_existing_limit_test() ->
    with_membership(fun() -> with_state(fun(S) ->
        Base=(adjustment_due(S))#{published := [<<"capture">>]},
        {noreply,Fractional}=measurement(<<"fractional">>,5,227000000,Base),
        tick(Fractional),expect_response(114),
        {noreply,Large}=measurement(<<"large">>,1,2000000000,Base),
        tick(Large),expect_response(3000),
        {noreply,Zero}=measurement(<<"zero">>,1,0,Base),
        tick(Zero),expect_response(0)
    end) end).

receiver_exit_stops_automatic_adjustment_test() ->
    with_state(fun(S) ->
        {noreply,S1}=activity([<<"capture">>],S),
        {Pid,Ref}=maps:get(receiver,S1),
        {noreply,S2}=ba_response_time:handle_info({'DOWN',Ref,process,Pid,normal},S1),
        ?assertMatch(#{published := [],receiver := undefined},S2),
        demonitor(Ref,[flush])
    end).

unchanged_response_does_not_create_another_signed_revision_test() ->
    Id= <<"device">>,
    [begin
        S=#{state => authorized,id => Id,response_ms => 113,response_auto => true,
            policy => #{<<"members">> => #{Id => #{<<"permissions">> => Permissions}}}},
        ?assertEqual({reply,ok,S},ba_session_membership:handle_call({response_time,#{<<"response_ms">> => 113}},undefined,S))
    end || Permissions <- [[<<"owner">>],[]]].

cadence_slows_with_observations_and_stops_at_the_limit_test() ->
    Initial=ba_cadence:new([500,1000,2000,4000,5000],1,0),
    lists:foldl(fun(Interval,Current) ->
        ?assertNot(ba_cadence:due(Current,Interval-1)),
        ?assert(ba_cadence:due(Current,Interval)),
        ba_cadence:schedule(ba_cadence:observe(Current,1),0)
    end,Initial,[500,1000,2000,4000,5000,5000]).

activity(Published,S) -> ba_response_time:handle_cast({activity,self(),[],[],false,Published},S).
tick(S) -> ba_response_time:handle_info(tick,S).
adjustment_due(#{adjust_cadence := Cadence}=S) ->
    S#{adjust_cadence := Cadence#{due := erlang:monotonic_time(millisecond)-1}}.
expect_response(Ms) ->
    receive {'$gen_cast',{response_time,#{<<"response_ms">> := Ms}}} -> ok
    after 0 -> ?assert(false) end.
expect_no_response() ->
    receive {'$gen_cast',{response_time,Request}} -> ?assertEqual(no_request,Request)
    after 0 -> ok end.
with_membership(F) ->
    true=register(ba_session_membership,self()),
    try F() after unregister(ba_session_membership) end.

measurement(Id,Count,Sum,S) ->
    ba_response_time:handle_cast({reported,Id,#{<<"count">> => Count,<<"sum_ns">> => Sum,
        <<"at">> => erlang:system_time(second)}},S).

playback(Revision,Playing,Started,S) ->
    ba_response_time:handle_cast({remote_playback,<<"peer">>,#{<<"playing">> => Playing,<<"failed">> => false,
        <<"started">> => Started,<<"revision">> => Revision}},S).

with_state(F) ->
    Table=ets:new(ba_response_time,[named_table]),
    try F(#{reports => #{},playback_states => #{},
        report_cadence => ba_cadence:new([250,500,750,1000,1250,1500,1750,2000],256,0),
        adjust_cadence => ba_cadence:new([500,1000,2000,4000,5000],1,0),
        offset_ms => 150,automatic => true,ready => true,published => [],
        receiver => undefined,active => [],started => [],failed => false,self => <<"local">>,revision_playback => 0})
    after ets:delete(Table) end.
