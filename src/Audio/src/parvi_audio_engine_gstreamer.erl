%% Current Windows webrtcbin/Opus/WASAPI execution, not a scheduled RTP backend.
-module(parvi_audio_engine_gstreamer).
-behaviour(parvi_audio_engine).
-export([info/0, available/0, open/1, command/2, event/2, close/1]).
info() ->
    #{id => <<"gstreamer">>, wire_profile => <<"webrtc_opus_rtp">>,
      formats => [#{encoding => opus, sample_rate => 48000, channel_count => 2}],
      output_sample_format => float32_le, jitter_buffer => true, loss_concealment => configured,
      timing_policy => pipeline_clock, minimum_delay_control => jitter_buffer_latency,
      output_callback_timing => false, reported_output_latency => false,
      source_output_mapping => false, presentation_schedule_execution => false,
      rate_correction_control => false}.
available() -> parvi_audio_native_engine:available().
open(Options) -> parvi_audio_native_engine:open(Options).
command(Handle, Command) -> parvi_audio_native_engine:command(Handle, Command).
event(Handle, Message) -> parvi_audio_native_engine:event(Handle, Message).
close(Handle) -> parvi_audio_native_engine:close(Handle).
