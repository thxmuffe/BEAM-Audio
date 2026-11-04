-module(parvi_audio_gstreamer_control_tests).
-include_lib("eunit/include/eunit.hrl").
descriptor() -> #{rtp_timestamp_semantics => global_playback_48k_v1,presentation_stream_id => <<"stream">>}.
reference() -> #{state => synchronized,timeline => <<"reference">>,filtered_utc_time => 1793820000000000000}.
observation(Time) -> #{rtp_timestamp => parvi_audio_rtp_time:encode(Time),generation => 1}.

packet_owns_target_without_periodic_anchor_test() ->
    T = 1793820001000000000,
    ?assertMatch({ok,#{target_output_time_ns := T,basis := packet_global_playback_target}},
        parvi_audio_gstreamer_control:target(descriptor(),observation(T),reference())).

unacquired_receiver_is_rejected_test() ->
    ?assertEqual({error,source_or_receiver_clock_unavailable},parvi_audio_gstreamer_control:target(
        descriptor(),observation(1793820001000000000),(reference())#{state := acquiring})).

legacy_stream_counter_is_not_a_target_test() ->
    ?assertEqual({error,packet_target_clock_unavailable},
        parvi_audio_gstreamer_control:target(#{},#{rtp_timestamp => 1000},reference())).

master_with_partial_coverage_can_schedule_test() ->
    ?assertMatch({ok,_},parvi_audio_gstreamer_control:target(descriptor(),observation(1793820001000000000),
        (reference())#{role => master,state => holdover,filter_ready => false})).
