-module(ba_audio_opus_tests).
-include_lib("eunit/include/eunit.hrl").

native_decoded_block_boundary_test() ->
    PCM = <<0.25:32/little-float,0.25:32/little-float>>,
    ?assertEqual({pcm,42,1,PCM},ba_audio_opus:event(port,{port,{data,<<1,42:32,1:32,PCM/binary>>}})),
    ?assertEqual(ignore,ba_audio_opus:event(port,{port,{data,<<1,42:32,2:32,PCM/binary>>}})),
    ?assertEqual(ignore,ba_audio_opus:event(port,{other,{data,<<3>>}})),
    ?assertEqual({error,<<"decoded_packet_target_missing">>},ba_audio_opus:event(port,{port,{data,<<2,"decoded_packet_target_missing">>}})),
    ?assertEqual(closed,ba_audio_opus:event(port,{port,{exit_status,1}})).

opus_offer_and_pcm_handoff_keep_the_same_clock_test() ->
    D = #{encoding => opus,sample_format => opus,sample_rate => 48000,channel_count => 2,
        clock => <<"clock-instance">>,stream_handler => webrtc_audio_opus,
        rtp_timestamp_semantics => global_playback_48k_v1},
    P = ba_audio_stream_protocol:offer(<<"music">>,binary:copy(<<"A">>,32),
        #{name => <<"Music">>,paused => false,profiles => #{channel => D}}),
    ?assertEqual(ok,ba_audio_stream_protocol:validate(P)),
    ?assertEqual(D,ba_audio_stream_protocol:descriptor(P)),
    ?assertMatch(#{encoding := pcm,sample_format := float32_le,clock := <<"clock-instance">>},ba_audio_opus:descriptor(D)),
    ?assertEqual(ba_media_session,ba_stream_handler_opus:session_module()).
