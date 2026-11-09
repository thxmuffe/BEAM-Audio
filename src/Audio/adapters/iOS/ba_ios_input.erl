%% iOS capture binding. Native buffers/timestamps only; portable code owns
%% publication, PCM interpretation, meters and presentation targets.
-module(ba_ios_input).
-behaviour(gen_server).
-export([start/1,stop/1,status/1,start_link/1]).
-export([init/1,handle_call/3,handle_cast/2,handle_info/2,terminate/2,format_status/1]).
name(microphone) -> ba_ios_microphone;
name(broadcast) -> ba_ios_broadcast.
start(K) ->
    ok=ba_audio_sup:ensure_started(),
    case supervisor:start_child(ba_audio_sup,#{id => name(K),start => {?MODULE,start_link,[K]},restart => temporary}) of
        {ok,P} -> gen_server:call(P,start);
        {error,{already_started,P}} -> gen_server:call(P,start);
        E -> E
    end.
stop(K) -> case whereis(name(K)) of undefined -> ok;P -> gen_server:call(P,stop) end.
status(K) -> case whereis(name(K)) of undefined -> #{state => stopped};P -> gen_server:call(P,status) end.
start_link(K) -> gen_server:start_link({local,name(K)},?MODULE,K,[]).
init(K) -> {ok,initial(K)}.
initial(K) -> #{kind => K,socket => undefined,input => ba_audio_input:new(),dropped_callbacks => 0}.
handle_call(start,_,#{socket := undefined,kind := K}=S) ->
    case ba_audio_input:ready() of
        ok ->
            case gen_tcp:connect({127,0,0,1},list_to_integer(os:getenv("BA_AUDIO_INPUT_PORT")),
                    [binary,{packet,4},{packet_size,131072},{active,once}],2000) of
                {ok,Socket} ->
                    Mode=case K of microphone -> 1;broadcast -> 2 end,
                    ok=gen_tcp:send(Socket,<<1,Mode>>),
                    {reply,ok,S#{socket := Socket,input := (ba_audio_input:new())#{state := starting}}};
                {error,R} -> {reply,{error,R},S}
            end;
        _ -> {reply,{error,waiting_for_clock},S}
    end;
handle_call(start,_,S) -> {reply,ok,S};
handle_call(stop,_,S) -> close(S),ba_audio_input:stop(maps:get(input,S)),{reply,ok,initial(maps:get(kind,S))};
handle_call(status,_,S) -> {reply,(ba_audio_input:status(maps:get(input,S)))#{dropped_callbacks => maps:get(dropped_callbacks,S)},S};
handle_call(_,_,S) -> {reply,{error,unsupported},S}.
handle_cast(_,S) -> {noreply,S}.
handle_info({tcp,Socket,Packet},#{socket := Socket}=S) ->
    try packet(Packet,S) of
        Next ->
            case maps:get(socket,Next) of undefined -> ok;_ -> inet:setopts(Socket,[{active,once}]) end,
            {noreply,Next}
    catch _:_ -> {noreply,fail(<<"Invalid iOS capture format or timestamp.">>,S)} end;
handle_info({tcp_closed,Socket},#{socket := Socket}=S) -> {noreply,fail(<<"iOS capture closed; toggle the capability to retry.">>,S)};
handle_info({tcp_error,Socket,_},#{socket := Socket}=S) -> {noreply,fail(<<"iOS capture connection failed.">>,S)};
handle_info({read,Socket},#{socket := Socket}=S) -> {noreply,read(S)};
handle_info({'DOWN',Ref,process,_,_},S) ->
    case ba_audio_input:source_monitor(Ref,maps:get(input,S)) of
        true -> {noreply,fail(<<"Audio publication closed.">>,S)};false -> {noreply,S}
    end;
handle_info(_,S) -> {noreply,S}.
packet(<<1,Rate:32,Channels:16>>,S) when Rate>=8000,Rate=<192000,Channels>=1,Channels=<2 ->
    K=maps:get(kind,S),{Name,Key}=case K of microphone -> {<<"iPhone microphone">>,<<"microphone">>};broadcast -> {<<"iPhone system audio">>,<<"default-output">>} end,
    Input=ba_audio_input:open(Name,#{encoding => pcm,sample_format => float32_le,sample_rate => Rate,channel_count => Channels},Key),
    read(S#{input := Input,channels => Channels});
packet(<<5,Host:64>>,#{sent := Sent}=S) ->
    Now=erlang:monotonic_time(nanosecond),RTT=Now-Sent,
    case RTT<maps:get(best_rtt,S,RTT+1) of
        true -> S#{host_offset => (Sent+Now) div 2-Host,best_rtt => RTT};false -> S
    end;
packet(<<2,Host:64,Frames:32,Dropped:64,Planes/binary>>,#{channels := C,host_offset := Offset}=S)
        when Frames>0,Frames=<4096,byte_size(Planes)=:=Frames*C*4 ->
    PCM=case C of
        1 -> Planes;
        2 -> <<Left:(Frames*4)/binary,Right/binary>>=Planes,
            iolist_to_binary([[binary:part(Left,I*4,4),binary:part(Right,I*4,4)] || I <- lists:seq(0,Frames-1)])
    end,
    Input=ba_audio_input:captured(PCM,Host+Offset,maps:get(input,S)),
    S#{input := Input,dropped_callbacks := Dropped};
packet(<<4>>,#{socket := Socket}=S) -> erlang:send_after(10,self(),{read,Socket}),S;
packet(<<3,Text/binary>>,S) -> fail(Text,S).
read(#{socket := Socket}=S) ->
    Sent=erlang:monotonic_time(nanosecond),ok=gen_tcp:send(Socket,<<$r>>),S#{sent => Sent}.
fail(Text,S) -> close(S),(initial(maps:get(kind,S)))#{input := ba_audio_input:failed(Text,maps:get(input,S))}.
close(#{socket := undefined}) -> ok;
close(#{socket := Socket}) -> gen_tcp:close(Socket).
terminate(_,S) -> close(S),ba_audio_input:close(maps:get(input,S)).
format_status(Status) -> maps:map(fun(state,S) -> maps:with([kind,dropped_callbacks],S);(log,_) -> [];(_,_) -> redacted end,Status).
