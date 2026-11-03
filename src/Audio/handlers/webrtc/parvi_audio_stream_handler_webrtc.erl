%% Explicit Opus/NetEq comparison; not the cluster-synchronized PCM handler.
-module(parvi_audio_stream_handler_webrtc).
-behaviour(parvi_audio_stream_handler).
-export([info/0, validate_descriptor/2, session_module/0, output_available/0,
         start_output/2, stop_output/1, output_control/2, bind/3, close/2]).
info() -> #{id => <<"webrtc_audio_opus">>, wire_profile => <<"webrtc_opus_rtp">>,
    transport => <<"webrtc_audio_track">>, jitter_buffer => true, loss_concealment => true,
    cluster_synchronized => false, presentation_schedule_execution => false,
    timing_policy => <<"receiver_engine">>, native_payload_bypass => false,
    codec => <<"opus">>, target_bitrate => 192000}.
validate_descriptor(channel, #{encoding := opus, sample_format := opus,
    sample_rate := 48000, channel_count := 2}) -> ok;
validate_descriptor(_, _) -> {error, unsupported_descriptor}.
session_module() -> parvi_webrtc_audio_session.
output_available() -> parvi_audio_engine:available().
output_control(Session,Command) -> gen_statem:call(Session,{output_control,Command}).
start_output(_, #{session := Session}) ->
    case gen_statem:call(Session, {playback, start}) of ok -> {ok, Session}; Error -> Error end.
stop_output(Session) ->
    try gen_statem:call(Session, {playback, stop}, 1000) catch exit:_ -> ok end.
bind(_, _, _) -> {error, native_session_required}.
close(_, _) -> ok.
