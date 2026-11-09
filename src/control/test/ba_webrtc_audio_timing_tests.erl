-module(ba_webrtc_audio_timing_tests).
-include_lib("eunit/include/eunit.hrl").

%% Deterministic UTC mapping through the real clock API, without starting a
%% cluster, contacting a time provider, or changing the machine clock.
with_clock(Fun) ->
    Table = ets:new(ba_swarm_clock,[named_table,set]),
    ets:insert(Table,{clock,#{role => master,timeline => <<"native-timing-test">>,confirmed => true,
        authorization_until => infinity,last_sync => erlang:monotonic_time(nanosecond),
        filter_ready => true,sample_interval_ms => 5000,
        mapping => ba_swarm_clock_mapping:new(0,2000000000)}}),
    try Fun() after ets:delete(Table) end.

observation(Input, Frames, Output, Host, Dropped) ->
    #{valid => true,position => Input,frames => Frames,output_position => Output,
      host_ns => Host,dropped => Dropped}.
observe(O,S) -> ba_webrtc_audio_timing:observe(O,S).
capture(P,S) -> ba_webrtc_audio_timing:capture(P,#{},S).
initial() -> #{clock_offset_ns => 1000}.

input_rate_and_position_are_not_encoded_indices_test() -> with_clock(fun() ->
    %% 44.1 kHz input starting at a nonzero OS sample position, 48 kHz output.
    A = observe(observation(441000,441,0,1000000000,0),initial()),
    B = observe(observation(441441,441,480,1010000000,0),A),
    C = capture(960,B),
    ?assertMatch(#{continuous := true,capture_segment := 1,
        estimated_capture_time_ns := 3020001000},C)
end).

gap_reanchors_without_resetting_encoded_position_test() -> with_clock(fun() ->
    A = observe(observation(0,480,0,1000000000,0),initial()),
    B = observe(observation(480,480,480,1010000000,0),A),
    Gap = observe(observation(4800,480,960,1100000000,1),B),
    ?assertMatch(#{continuous := false,estimated_capture_time_ns := null},capture(960,Gap)),
    Recovered = observe(observation(5280,480,1440,1110000000,1),Gap),
    ?assertMatch(#{continuous := true,capture_segment := 2,sample_position := 1920,
        estimated_capture_time_ns := 3120001000},capture(1920,Recovered))
end).

packet_spanning_nominal_boundary_stays_unavailable_test() -> with_clock(fun() ->
    A = observe(observation(0,480,0,1000000000,0),initial()),
    Gap = observe(observation(4800,480,1440,1100000000,1),A),
    Recovered = observe(observation(5280,480,1920,1110000000,1),Gap),
    ?assertMatch(#{continuous := false,estimated_capture_time_ns := null},capture(960,Recovered)),
    ?assertMatch(#{continuous := true,segment_start_position := 1920,
        estimated_capture_time_ns := 3110001000},capture(1920,Recovered))
end).

invalid_timestamp_and_input_reset_recover_test() -> with_clock(fun() ->
    A = observe(observation(10000,480,0,1000000000,0),initial()),
    Invalid = observe(#{valid => false},A),
    ?assertMatch(#{continuous := false,estimated_capture_time_ns := null},capture(0,Invalid)),
    First = observe(observation(0,480,480,2000000000,0),Invalid),
    ?assertMatch(#{continuous := false},capture(960,First)),
    Second = observe(observation(480,480,960,2010000000,0),First),
    ?assertMatch(#{continuous := true,capture_segment := 2,
        estimated_capture_time_ns := 4010001000},capture(960,Second))
end).

position_gap_or_drop_counter_alone_invalidates_test() ->
    A = observe(observation(0,480,0,1000000000,0),initial()),
    [begin
        Gap = observe(O,A),
        ?assertMatch(#{continuous := false,capture_segment := 2},capture(960,Gap))
     end || O <- [observation(960,480,480,1020000000,0),
                   observation(480,480,480,1010000000,1)]].

timeline() -> #{rtp_timestamp => 100,sample_position => 2880,
    segment_start_position => 1920,capture_segment => 2,continuous => true,
    estimated_capture_time_ns => 3200000000}.
stats(Delta) -> #{<<"sourceRtpTimestamp">> => (100+Delta) band 16#ffffffff,
    <<"sourceTimestampUs">> => 1230000,<<"sourceObservedHostTimeNs">> => 1230001000,
    <<"packetsReceived">> => 10,<<"estimated_capture_to_track_ms">> => 999,
    <<"track_delivery_time_ns">> => 999,<<"native_clock_round_trip_ns">> => 999}.
clock() -> #{offset_ns => 1000,round_trip_ns => 2000}.

old_segment_rejected_and_exact_boundary_accepted_across_rtp_wrap_test() -> with_clock(fun() ->
    Old = ba_webrtc_audio_timing:report(timeline(),stats(-961),clock()),
    ?assertEqual(<<"waiting_for_current_capture_segment">>,maps:get(<<"capture_timing_status">>,Old)),
    assert_no_estimate(Old),
    Current = ba_webrtc_audio_timing:report(timeline(),stats(-960),clock()),
    ?assertEqual(<<"available">>,maps:get(<<"capture_timing_status">>,Current)),
    ?assert(abs(maps:get(<<"estimated_capture_to_track_ms">>,Current)-50.001) < 0.000001),
    ?assertEqual(3230001000,maps:get(<<"track_delivery_time_ns">>,Current))
end).

unavailable_reports_clear_old_estimates_test() -> with_clock(fun() ->
    Interrupted = (timeline())#{continuous := false,estimated_capture_time_ns := null},
    Stale = (stats(0))#{<<"sourceObservedHostTimeNs">> := 12000000000},
    [assert_no_estimate(R) || R <- [
        ba_webrtc_audio_timing:report(undefined,stats(0),clock()),
        ba_webrtc_audio_timing:report(Interrupted,stats(0),clock()),
        ba_webrtc_audio_timing:report(timeline(),Stale,clock()),
        ba_webrtc_audio_timing:report(timeline(),stats(0),undefined)]]
end).

assert_no_estimate(Report) ->
    ?assertEqual(10,maps:get(<<"packetsReceived">>,Report)),
    [?assertNot(maps:is_key(K,Report)) || K <- [<<"estimated_capture_to_track_ms">>,
        <<"track_delivery_time_ns">>,<<"native_clock_round_trip_ns">>]], ok.

per_packet_schedule_report_does_not_need_anchors_test() ->
    Native = #{<<"sinkScheduleEnforced">> => true,<<"packetTargetExecution">> => true,
        <<"appliedSchedule">> => #{<<"basis">> => <<"packet_global_playback_target">>,
            <<"rtp_timestamp">> => 12,<<"target_output_time_ns">> => 1793820001000000000}},
    Report = ba_webrtc_audio_timing:report(undefined,Native,undefined),
    ?assertEqual(true,maps:get(<<"output_schedule_enforced">>,Report)),
    NoPacket = ba_webrtc_audio_timing:report(undefined,maps:remove(<<"packetTargetExecution">>,Native),undefined),
    ?assertEqual(false,maps:get(<<"output_schedule_enforced">>,NoPacket)).
