%% Explicit development-only AAC profile; never selected by legacy peers.
-module(ba_stream_handler_native).
-behaviour(ba_stream_handler).
-export([info/0,validate_descriptor/2,session_module/0,output_available/0,start_output/2,stop_output/1,output_control/2,bind/3,close/2]).
info() -> #{id => <<"native_gst_aac">>,wire_profile => <<"gst_aac_rtp_v1">>,codec => <<"aac_lc">>,target_bitrate => 320000,
    native_payload_bypass => true,cluster_synchronized => false}.
validate_descriptor(channel,#{encoding := pcm,sample_format := float32_le,sample_rate := R,channel_count := 2,
    stream_handler := native_gst_aac}) when R=:=44100;R=:=48000 -> ok;
validate_descriptor(_,_) -> {error,unsupported_native_descriptor}.
session_module() -> ba_native_media_session.
output_available() -> ba_native_media_session:available().
start_output(Pid,_) -> gen_server:call(Pid,{output,play}).
stop_output(Pid) -> gen_server:call(Pid,{output,pause}).
output_control(Pid,{gain,G}) -> gen_server:call(Pid,{gain,G});
output_control(_,_) -> {error,native_schedule_not_implemented}.
bind(_,_,_) -> {error,native_session_required}.
close(_,_) -> ok.
