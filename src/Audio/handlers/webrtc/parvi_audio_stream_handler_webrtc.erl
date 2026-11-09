%% WebRTC/Opus transport with explicit global per-packet playback targets.
-module(parvi_audio_stream_handler_webrtc).
-behaviour(parvi_audio_stream_handler).
-export([info/0, validate_descriptor/2, session_module/0, output_available/0,
         start_output/2, stop_output/1, output_control/2, bind/3, close/2]).
info() ->
    #{id => <<"webrtc_audio_opus">>, wire_profile => <<"webrtc_opus_rtp">>,
    transport => <<"webrtc_audio_track">>, jitter_buffer => true, loss_concealment => true,
    cluster_synchronized => false,
    presentation_schedule_execution => true,decoded_audio_handoff => parvi_audio_opus:available(),
    rtp_timestamp_semantics => global_playback_48k_v1,
    timing_policy => <<"packet_global_target">>, native_payload_bypass => false,
    codec => <<"opus">>, target_bitrate => 192000}.
validate_descriptor(channel, #{encoding := opus, sample_format := opus,
    sample_rate := 48000, channel_count := 2, rtp_timestamp_semantics := global_playback_48k_v1}) -> ok;
validate_descriptor(_, _) -> {error, unsupported_descriptor}.
session_module() -> parvi_audio_subscription.
output_available() -> parvi_audio_opus:available() andalso parvi_audio_output:available().
output_control(_,_) -> {error,use_subscription_mixer}.
start_output(_,_) -> {error,use_subscription_mixer}.
stop_output(_) -> ok.
bind(_, _, _) -> {error, native_session_required}.
close(_, _) -> ok.
