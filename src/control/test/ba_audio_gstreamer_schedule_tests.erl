-module(ba_audio_gstreamer_schedule_tests).
-include_lib("eunit/include/eunit.hrl").

pipeline() -> #{host_ns => 1000000000,pipeline_clock_ns => 8000000000,
    base_time_ns => 7000000000,running_time_ns => 500000000,
    pipeline_latency_ns => 200000000,render_delay_ns => 10000000,
    observation_uncertainty_ns => 1000}.
target() -> #{local_handoff_time_ns => 2500000000,revision => 3,
              stream_id => <<"stream">>,clock_timeline => <<"clock">>}.

sink_target_accounts_for_latency_once_test() ->
    {ok,Plan} = ba_audio_gstreamer_schedule:plan(target(),#{offset_ns => 500000000},pipeline()),
    ?assertMatch(#{native_target_ns := 2000000000,pipeline_target_ns := 9000000000,
        ts_offset_ns := 1310000000,revision := 3},Plan),
    #{base_time_ns := Base,running_time_ns := Running,pipeline_latency_ns := Latency,
      render_delay_ns := RenderDelay} = pipeline(),
    ?assertEqual(9000000000,Base+Running+maps:get(ts_offset_ns,Plan)+Latency-RenderDelay).

future_pts_can_require_negative_sink_offset_test() ->
    P = (pipeline())#{running_time_ns := 3000000000},
    {ok,Plan} = ba_audio_gstreamer_schedule:plan(target(),#{offset_ns => 500000000},P),
    ?assertEqual(-1190000000,maps:get(ts_offset_ns,Plan)).

late_or_missing_observations_are_not_accepted_test() ->
    ?assertEqual({error,target_not_in_future},ba_audio_gstreamer_schedule:plan(
        (target())#{local_handoff_time_ns := 1500000000},#{offset_ns => 500000000},pipeline())),
    ?assertEqual({error,incomplete_pipeline_observation},ba_audio_gstreamer_schedule:plan(
        target(),#{offset_ns => 0},maps:remove(pipeline_latency_ns,pipeline()))).

source_rtp_wrap_and_retained_frame_offset_test() ->
    Anchor = #{rtp_timestamp => 16#ffffff00,sample_position => 960},
    ?assertEqual({ok,1488},ba_audio_gstreamer_schedule:source_position(Anchor,16#100,16)),
    ?assertEqual({error,stale_source_anchor},
        ba_audio_gstreamer_schedule:source_position(Anchor,480000,0)),
    ?assertEqual({error,source_anchor_unavailable},
        ba_audio_gstreamer_schedule:source_position(undefined,0,0)).

rate_change_preserves_phase_and_enforces_bound_test() ->
    Clock = #{internal_ns => 3000,calibration_internal_ns => 1000,
        calibration_external_ns => 5000,rate_numerator => 2,rate_denominator => 1},
    ?assertEqual({ok,#{internal_ns => 3000,external_ns => 9000,
        rate_numerator => 1000025000,rate_denominator => 1000000000}},
        ba_audio_gstreamer_schedule:rate_plan(#{correction_ppm => 25,max_absolute_ppm => 50},Clock)),
    ?assertEqual({error,invalid_or_out_of_bounds_rate_correction},
        ba_audio_gstreamer_schedule:rate_plan(#{correction_ppm => 51,max_absolute_ppm => 50},Clock)),
    ?assertEqual({error,invalid_or_out_of_bounds_rate_correction},
        ba_audio_gstreamer_schedule:rate_plan(#{correction_ppm => -1000000,max_absolute_ppm => 1000000},Clock)),
    ?assertEqual({error,invalid_or_out_of_bounds_rate_correction},
        ba_audio_gstreamer_schedule:rate_plan(#{correction_ppm => -999999.9999,max_absolute_ppm => 1000000},Clock)).
