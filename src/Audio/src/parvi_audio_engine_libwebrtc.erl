%% iPhone libwebrtc/NetEq + RemoteIO, behind the common media execution contract.
-module(parvi_audio_engine_libwebrtc).
-behaviour(parvi_audio_engine).
-export([info/0, available/0, open/1, command/2, event/2, close/1]).
info() ->
    #{id => <<"libwebrtc">>, wire_profile => <<"webrtc_opus_rtp">>,
      formats => [#{encoding => opus, sample_rate => 48000, channel_count => 2}],
      output_sample_format => s16, jitter_buffer => true, loss_concealment => true,
      adaptive_playout => true, minimum_delay_control => minimum_only,
      output_callback_timing => true, reported_output_latency => true,
      source_output_mapping => false, presentation_schedule_execution => false,
      rate_correction_control => false}.
available() -> parvi_audio_native_engine:available().
open(Options) -> parvi_audio_native_engine:open(Options).
command(Handle, Command) -> parvi_audio_native_engine:command(Handle, Command).
event(Handle, Message) -> parvi_audio_native_engine:event(Handle, Message).
close(Handle) -> parvi_audio_native_engine:close(Handle).
