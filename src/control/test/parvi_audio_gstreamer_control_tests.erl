-module(parvi_audio_gstreamer_control_tests).
-include_lib("eunit/include/eunit.hrl").
source() -> #{continuous => true,rtp_timestamp => 1000,sample_position => 48000,
    segment_start_position => 0,presentation => #{clock_timeline => <<"reference">>,
        stream_id => <<"stream">>,revision => 2,sample_position => 48000,
        sample_rate => 48000,target_output_time_ns => 5000000000}}.
reference() -> #{state => synchronized,timeline => <<"reference">>}.

same_sample_deadline_on_matching_clock_test() ->
    ?assertMatch({ok,#{sample_position := 48960,target_output_time_ns := 5020000000}},
        parvi_audio_gstreamer_control:target(source(),#{rtp_timestamp => 1960},reference())).

wrong_or_acquiring_clock_does_not_schedule_test() ->
    [ ?assertEqual({error,source_or_receiver_clock_unavailable},
        parvi_audio_gstreamer_control:target(source(),#{rtp_timestamp => 1000},Reference))
      || Reference <- [#{state => synchronized,timeline => <<"other">>},
                       #{state => acquiring,timeline => <<"reference">>}]],
    ?assertEqual({error,source_or_receiver_clock_unavailable},
        parvi_audio_gstreamer_control:target((source())#{continuous := false},
            #{rtp_timestamp => 1000},reference())).

old_capture_samples_are_not_reused_test() ->
    ?assertEqual({error,previous_capture_segment},parvi_audio_gstreamer_control:target(
        (source())#{segment_start_position => 48000},#{rtp_timestamp => 40},reference())).

bounded_servo_has_correct_direction_and_relocks_test() ->
    ?assertMatch(#{correction_ppm := -50.0},parvi_audio_gstreamer_control:correction(1000000,0)),
    ?assertMatch(#{correction_ppm := 50.0},parvi_audio_gstreamer_control:correction(0,1000000)),
    ?assertMatch(#{correction_ppm := P} when abs(P) < 0.001,
        parvi_audio_gstreamer_control:correction(100,100)),
    ?assertEqual(relock,parvi_audio_gstreamer_control:correction(21000000,0)).
