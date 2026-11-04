-module(parvi_audio_rtp_time_tests).
-include_lib("eunit/include/eunit.hrl").

independent_packet_targets_test() ->
    Now = 1793820000000000000,
    %% Deliberately nonuniform targets, received backwards with neighbours lost.
    Targets = [Now+1000000000,Now+1020375000,Now+1712345678],
    [begin
        Assigned = parvi_audio_rtp_time:quantize(T),
        ?assertEqual({ok,Assigned},parvi_audio_rtp_time:decode(
            parvi_audio_rtp_time:encode(Assigned),Now)),
        ?assert(abs(Assigned-T) =< 10417)
    end || T <- lists:reverse(Targets)].

wrap_is_resolved_without_previous_packet_test() ->
    %% Same clock, adjacent packets straddling the 32-bit RTP wrap.
    WrapTicks = 20000*(1 bsl 32),
    Boundary = WrapTicks*1000000000 div 48000,
    [begin
        Target = parvi_audio_rtp_time:quantize(Boundary+Offset),
        ?assertEqual({ok,Target},parvi_audio_rtp_time:decode(
            parvi_audio_rtp_time:encode(Target),Boundary-1000000000))
    end || Offset <- [20000000,-20000000,0]].

source_assignment_is_exactly_representable_test() ->
    Header = #{continuous => true,estimated_capture_time_ns => 1793820000000000001,
        sample_position => 0,sample_rate => 48000,capture_segment => 1},
    {#{presentation := #{target_output_time_ns := Assigned}},_} =
        parvi_audio_presentation:stamp(Header,1000000000,<<"clock">>,#{stream_id => <<"source">>}),
    ?assertEqual({ok,Assigned},parvi_audio_rtp_time:decode(
        parvi_audio_rtp_time:encode(Assigned),1793820000000000000)).

missing_target_never_creates_packet_test() ->
    [ ?assertEqual({error,packet_playback_target_unavailable},
        parvi_audio_rtp_time:packet(<<1,2>>,Timing,4,false))
      || Timing <- [#{},#{continuous => true},
          #{continuous => false,presentation => #{target_output_time_ns => 123}}] ].

distant_or_invalid_target_is_rejected_test() ->
    Now = 1793820000000000000,
    ?assertEqual({error,packet_target_out_of_window},parvi_audio_rtp_time:decode(
        parvi_audio_rtp_time:encode(Now+61000000000),Now)),
    ?assertEqual({error,invalid_packet_target},parvi_audio_rtp_time:decode(-1,Now)).

legacy_descriptor_is_rejected_test() ->
    Legacy = #{encoding => opus,sample_format => opus,sample_rate => 48000,channel_count => 2},
    ?assertEqual({error,unsupported_descriptor},
        parvi_audio_stream_handler_webrtc:validate_descriptor(channel,Legacy)),
    ?assertEqual(ok,parvi_audio_stream_handler_webrtc:validate_descriptor(channel,
        Legacy#{rtp_timestamp_semantics => global_playback_48k_v1})).
