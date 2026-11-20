%% Local media implementation boundary; existing OTP workers retain ownership.
-module(ba_stream_handler).
-export([for_descriptor/1]).

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

-optional_callbacks([send/3, push_output/3]).

%% One transport: native AAC (owner decision 2026-11-19). Remote descriptors
%% cannot name modules.
for_descriptor(#{stream_handler := native_gst_aac}) -> ba_stream_handler_native.
