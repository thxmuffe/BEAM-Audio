%% The one audio transport: FLAC over SRTP, carried by the native audio engine
%% under Erlang control (owner decision 2026-11-20; see docs/AUDIO_ENGINE.md).
-module(ba_stream_handler_engine).
-behaviour(ba_stream_handler).
-export([info/0,validate_descriptor/2,session_module/0,output_available/0,start_output/2,stop_output/1,bind/3,close/2]).
info() -> #{id => <<"engine_flac">>,wire_profile => ba_audio_stream_protocol:wire_profile(),codec => <<"flac">>,
    native_payload_bypass => true,cluster_synchronized => true}.
validate_descriptor(channel,#{encoding := pcm,sample_format := float32_le,sample_rate := R,channel_count := 2,
    stream_handler := engine_flac}) when R=:=44100;R=:=48000 -> ok;
validate_descriptor(_,_) -> {error,unsupported_engine_descriptor}.
session_module() -> ba_engine_media_session.
output_available() -> ba_audio_engine:available().
start_output(Pid,_) -> gen_server:call(Pid,{output,play}).
stop_output(Pid) -> gen_server:call(Pid,{output,pause}).
bind(_,_,_) -> {error,engine_session_required}.
close(_,_) -> ok.
