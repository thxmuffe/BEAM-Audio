%% Local binding to the approved GStreamer decode path. Erlang owns all targets.
-module(parvi_audio_opus).
-export([available/0,open/0,push/2,event/2,close/1,descriptor/1]).
available() -> os:getenv("PARVI_GSTREAMER_PCM_HELPER")=/=false andalso os:getenv("PARVI_GSTREAMER_PYTHON")=/=false.
open() ->
    case available() of
        false -> {error,opus_decoder_unavailable};
        true ->
            Python = os:getenv("PARVI_GSTREAMER_PYTHON"),Helper = os:getenv("PARVI_GSTREAMER_PCM_HELPER"),
            Port = open_port({spawn_executable,Python},[binary,{packet,4},exit_status,use_stdio,
                {busy_limits_msgq,{65536,131072}},{args,[Helper]}]),
            {ok,Port}
    end.
push(Port,Packet) when is_binary(Packet),byte_size(Packet)=<16384 ->
    case port_command(Port,Packet,[nosuspend]) of true -> ok;false -> {error,decoder_busy} end.
event(Port,{Port,{data,<<1,RTP:32,Frames:32,PCM/binary>>}}) when Frames>0,Frames=<4096,byte_size(PCM)=:=Frames*8 -> {pcm,RTP,Frames,PCM};
event(Port,{Port,{data,<<2,Reason/binary>>}}) when byte_size(Reason)=<64 -> {error,Reason};
event(Port,{Port,{data,<<3>>}}) -> ready;
event(Port,{Port,{exit_status,_}}) -> closed;
event(_,_) -> ignore.
close(Port) -> try port_close(Port) catch error:badarg -> ok end.
descriptor(#{encoding := opus,clock := Clock}) ->
    #{encoding => pcm,sample_format => float32_le,sample_rate => 48000,channel_count => 2,clock => Clock};
descriptor(D) -> D.
