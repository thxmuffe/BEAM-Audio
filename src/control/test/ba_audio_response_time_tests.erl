-module(ba_audio_response_time_tests).
-include_lib("eunit/include/eunit.hrl").

average_lateness_is_added_to_current_response_time_test() ->
    P=#{revision => 4,offset_ms => 300,automatic => false},
    A=ba_audio_response_time:add(20000000,P,#{}),
    ?assertEqual(none,ba_audio_response_time:summary(A)),
    B=ba_audio_response_time:add(80000000,P,A),
    R=ba_audio_response_time:summary(B),
    ?assertMatch(#{discarded := 2,mean_late_ms := 50,required_ms := 350,response_ms := 300},R),
    ?assertNotEqual(nomatch,binary:match(ba_audio_response_time:text(R),<<"350 ms">>)),
    %% Measurements from another Response time cannot compound an old delta.
    ?assertEqual(none,ba_audio_response_time:summary(ba_audio_response_time:add(1000000,P#{revision := 5,offset_ms := 800},B))).

unknown_native_lateness_is_never_guessed_test() ->
    P=#{revision => 1,offset_ms => 150},
    R=ba_audio_response_time:summary(ba_audio_response_time:add(unknown,P,ba_audio_response_time:add(unknown,P,#{}))),
    ?assertMatch(#{discarded := 2},R),?assertNot(maps:is_key(required_ms,R)),
    One=ba_audio_response_time:summary(ba_audio_response_time:add(1000000,P,ba_audio_response_time:add(unknown,P,#{}))),
    ?assertNot(maps:is_key(required_ms,One)).

mixer_summarizes_actual_late_drops_without_retiming_test() ->
    ets:new(ba_buffee_clock,[named_table,protected]),register(ba_buffee_chat,self()),
    try
        T=erlang:monotonic_time(nanosecond),UTC=erlang:system_time(nanosecond),
        Policy=#{<<"revision">> => 1,<<"offset_ms">> => 300},
        Clock=#{role => master,mapping => ba_buffee_clock_mapping:new(T,UTC-T),timeline => <<"deadline-test">>,
            confirmed => true,authorization_until => infinity,last_sync => T,filter_ready => true,sample_interval_ms => 5000,
            offset => Policy,offset_until => infinity},
        ets:insert(ba_buffee_clock,{clock,Clock}),
        D=#{sample_rate => 48000,channel_count => 1,sample_format => float32_le,clock => <<"deadline-test">>,
            authorization_deadline => erlang:monotonic_time(millisecond)+10000},
        Mix=ba_audio_mix:enable(source,true,ba_audio_mix:add(source,1.0,ba_audio_mix:new(48000,<<"deadline-test">>))),
        S=#{mix => Mix,descriptors => #{source => D},dropped => 0,last_error => null},
        H=#{playback_time => UTC-50000000,frame_count => 1},
        Message={packet,source,D,H,<<0.25:32/little-float>>},
        {noreply,A}=ba_audio_mixer:handle_cast(Message,S),
        {noreply,B}=ba_audio_mixer:handle_cast(Message,A),
        {noreply,Done}=ba_audio_mixer:handle_info(report_lateness,B),
        ?assertEqual(2,maps:get(dropped,Done)),?assertEqual(Mix,maps:get(mix,Done)),
        ?assertNot(maps:is_key(lateness,Done)),
        receive {audio_lateness,#{discarded := 2,mean_late_ms := Mean,required_ms := Required}} ->
            ?assert(Mean>=50),?assertEqual(300+Mean,Required)
        after 1000 -> error(no_deadline_warning) end
    after unregister(ba_buffee_chat),ets:delete(ba_buffee_clock) end.

automatic_increases_taper_and_never_jump_to_three_seconds_test() ->
    Changes=[ba_audio_response_time:increase(C,C+100)-C || C <- [300,600,1000,2000,2900]],
    ?assertEqual([75,33,14,1,0],Changes),
    ?assertEqual(800,ba_audio_response_time:increase(800,700)),
    ?assert(ba_audio_response_time:increase(150,30000)<450),
    End=lists:foldl(fun(_,C) -> ba_audio_response_time:increase(C,30000) end,150,lists:seq(1,10000)),
    ?assert(End<3000),?assertEqual(3000,ba_audio_response_time:increase(3000,30000)).
