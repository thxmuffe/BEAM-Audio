%% Local media implementation boundary; existing OTP workers retain ownership.
-module(parvi_audio_stream_handler).
-export([default/0, for_descriptor/1]).

-callback info() -> map().
-callback session_module() -> module().
-callback validate_descriptor(atom(), map()) -> ok | {error, term()}.
-callback bind(expect | open, binary(), node()) -> {ok, pid()} | {error, term()}.
-callback send(pid(), binary(), binary()) -> ok | {error, term()}.
-callback close(pid(), binary()) -> term().
-callback output_available() -> boolean().
-callback start_output(pid(), map()) -> {ok, pid()} | {error, term()}.
-callback push_output(pid(), map(), binary()) -> ok.
-callback stop_output(pid()) -> ok.
-callback output_control(pid(), {minimum_delay, automatic | non_neg_integer()} |
    {presentation, parvi_audio_engine:presentation()} |
    {rate_correction, parvi_audio_engine:rate_correction()}) -> ok | {ok, map()} | {error, term()}.

%% Data callbacks for the existing BEAM PCM path. A native handler must gain
%% its actual control/handoff interface, rather than routing native buffers
%% through these callbacks just to fit the legacy implementation.
-callback validate_block(atom(), map(), map(), binary()) -> ok | {error, term()}.
-callback encode(atom(), map(), term(), map(), binary()) -> filtered | {ok, binary()} | {error, term()}.
-callback decode(atom(), map(), binary()) -> {ok, map(), binary()} | {error, term()}.
-callback frame_bytes(map()) -> pos_integer().
-callback max_payload_bytes(atom()) -> pos_integer().
-optional_callbacks([send/3, push_output/3, validate_block/4, encode/5, decode/3,
                     frame_bytes/1, max_payload_bytes/1]).

%% Default PCM compatibility handler. Pin it for each worker's lifetime; add
%% selection/negotiation only when another implementation has been demonstrated.
default() -> parvi_audio_stream_handler_legacy.

%% Explicit installed handlers only; remote descriptors cannot name modules.
for_descriptor(#{stream_handler := webrtc_audio_opus}) -> parvi_audio_stream_handler_webrtc;
for_descriptor(D) when not is_map_key(stream_handler,D) -> default().
