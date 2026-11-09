%% PCM Stream Handler: packet format, WebRTC media session and output binding.
-module(ba_stream_handler_pcm).
-behaviour(ba_stream_handler).
-export([info/0, session_module/0, bind/3, send/3, close/2, output_available/0,
         start_output/2, push_output/3, stop_output/1, output_control/2,
         validate_descriptor/2, validate_block/4, encode/5, decode/3,
         frame_bytes/1, max_payload_bytes/1]).

session_module() -> ba_media_session.
info() ->
    #{id => <<"pcm_webrtc">>, wire_profile => <<"parvi_pcm_v1">>,
      transport => <<"webrtc_datachannel">>, native_payload_bypass => false,
      ordered_delivery => false, retransmission => false,
      reorder_buffer => false, sample_clock_correction => false,
      jitter_buffer => false, loss_concealment => false,
      data_path => <<"erlang_pcm">>, timing_policy => <<"erlang">>}.

validate_descriptor(Profile, Descriptor) -> ba_audio_packet:validate_descriptor(Profile, Descriptor).
frame_bytes(Descriptor) -> ba_audio_packet:frame_bytes(Descriptor).
max_payload_bytes(Profile) -> ba_audio_packet:max_payload_bytes(Profile).
validate_block(Profile, Descriptor, Header, PCM) ->
    ba_audio_packet:validate_block(Profile, Descriptor, Header, PCM).
encode(Profile, Descriptor, Selector, Header, PCM) ->
    case ba_audio_packet:selected(Profile, Selector, Header) of
        false -> filtered;
        true -> ba_audio_packet:encode(Profile, Descriptor, Header, PCM)
    end.
decode(Profile, Descriptor, Packet) -> ba_audio_packet:decode(Profile, Descriptor, Packet).

%% The old OTP-distribution media carrier is retired.
bind(_,_,_) -> {error,use_scoped_subscription}.
send(_,_,_) -> {error,use_scoped_subscription}.
close(_,_) -> ok.

output_available() -> ba_audio_output:available().
start_output(Owner, Descriptor) ->
    case application:get_env(ba_core, audio_output_adapter) of
        {ok, Adapter} ->
            supervisor:start_child(ba_audio_sup,
                #{id => {output, make_ref()},
                  start => {ba_audio_output, start_link, [Owner, Descriptor, Adapter]},
                  restart => temporary});
        _ -> {error, <<"Audio output is unavailable on this device.">>}
    end.
push_output(Output, Header, PCM) -> ba_audio_output:push(Output, Header, PCM).
stop_output(Output) -> ba_audio_output:stop(Output).

%% Legacy scheduling is per PCM block; it has no native session control API.
output_control(_,_) -> {error, unsupported_output_control}.
