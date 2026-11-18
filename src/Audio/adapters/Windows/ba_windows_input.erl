%% Windows capture adapter (ba_audio_capture.exe, WASAPI) for the shared audio
%% Worker. Port lifetime and QPC clock mapping only; publication, meters and
%% presentation targets are ba_audio_input's, exactly as on macOS.
%% microphone: default capture device. broadcast: system output of every
%% process except this VM's tree, so this Device's own Session playback (its
%% output helper is a child of this VM) is never captured back into the Session.
-module(ba_windows_input).
-behaviour(gen_server).
-export([start/1,stop/1,status/1,unavailable/0,start_link/1]).
-export([init/1,handle_call/3,handle_cast/2,handle_info/2,terminate/2,format_status/1]).

helper() -> ba_settings:env("BA_WINDOWS_AUDIO_CAPTURE_HELPER").
available() -> case helper() of false -> false;P -> filelib:is_regular(P) end.
%% Every UI greys out what this Device cannot capture, with the reason.
unavailable() ->
    case available() of
        true -> #{};
        false -> R = <<"Audio capture helper is missing; rebuild the Windows app.">>,
                 #{<<"microphone">> => R,<<"broadcast">> => R}
    end.
name(broadcast) -> ba_windows_broadcast;
name(microphone) -> ba_windows_microphone.

start(Kind) when Kind=:=microphone;Kind=:=broadcast ->
    case ba_audio_sup:ensure_started() of
        ok ->
            case supervisor:start_child(ba_session_scope:ref(ba_audio_sup),
                    #{id => name(Kind),start => {?MODULE,start_link,[Kind]},restart => temporary}) of
                {ok,Pid} -> gen_server:call(Pid,start);
                {error,{already_started,Pid}} -> gen_server:call(Pid,start);
                Error -> Error
            end;
        Error -> Error
    end.
stop(Kind) -> case ba_session_scope:whereis(name(Kind)) of undefined -> ok;Pid -> gen_server:call(Pid,stop) end.
status(Kind) ->
    case ba_session_scope:whereis(name(Kind)) of
        undefined -> #{state => stopped,available => available()};
        Pid -> gen_server:call(Pid,status)
    end.
start_link(Kind) -> gen_server:start_link(ba_session_scope:registration(name(Kind)),?MODULE,Kind,[]).
init(Kind) -> process_flag(trap_exit,true),{ok,initial(Kind)}.
initial(Kind) -> #{kind => Kind,port => undefined,input => ba_audio_input:new()}.

handle_call({revoke_permissions,_},_,S) -> {Result,Next}=stop_confirmed(S),{reply,Result,Next};
handle_call(start,_,#{kind := Kind}=S) ->
    case ba_device_permission:allowed(Kind) of
        true -> case ba_device_permission:enter(Kind) of {ok,T} -> capture_start(S#{permission_token => T});E -> {reply,E,S} end;
        false -> {reply,{error,consent_required},S}
    end;
handle_call(stop,_,S) -> {Result,Next}=stop_confirmed(S),{reply,Result,Next};
handle_call(status,_,S) ->
    Diagnostics=maps:with([kind,capture_clock_uncertainty_ns,silent_packets,clock_reanchors],S),
    Public=maps:merge(Diagnostics,ba_audio_input:status(maps:get(input,S))),
    {reply,Public#{available => available()},S};
handle_call(_,_,S) -> {reply,{error,unsupported_request},S}.
handle_cast(_,S) -> {noreply,S}.

handle_info(Message,S) ->
    case maps:get(port,S)=/=undefined andalso not ba_device_permission:valid(maps:get(kind,S),maps:get(permission_token,S,legacy)) of
        true -> case maps:get(stop_result,S,undefined) of undefined -> {_,Next}=stop_confirmed(S),{noreply,Next};_ -> {noreply,S} end;
        false -> input_info(Message,S)
    end.
input_info({Port,{data,<<1,Rate:32/little,Channels:32/little>>}},#{port := Port,kind := Kind}=S) ->
    Descriptor=#{encoding => pcm,sample_format => float32_le,sample_rate => Rate,channel_count => Channels},
    {Name,Key}=case Kind of
        broadcast -> {<<"Windows default output">>,<<"default-output">>};
        microphone -> {<<"Windows microphone">>,<<"microphone">>}
    end,
    Input=ba_audio_input:open(Name,Descriptor,Key),
    {noreply,calibrate(S#{input := Input})};
%% Map QPC to Erlang monotonic time at the request midpoint; keep the best
%% (lowest round trip) reading. Both clocks are QPC-based, so it stays valid.
input_info({Port,{data,<<3,Qpc:64/little>>}},#{port := Port,request_sent := Sent}=S) ->
    Now=erlang:monotonic_time(nanosecond),RTT=Now-Sent,
    Next=case RTT<maps:get(best_round_trip,S,RTT+1) of
        true -> S#{host_offset => (Sent+Now) div 2-Qpc,best_round_trip => RTT,capture_clock_uncertainty_ns => RTT div 2};
        false -> S
    end,
    erlang:send_after(1000,self(),{calibrate,Port}),
    {noreply,Next};
input_info({calibrate,Port},#{port := Port}=S) -> {noreply,calibrate(S)};
input_info({Port,{data,<<2,_Qpc:64/little,_Frames:32/little,_Flags:32/little,_/binary>>}},#{port := Port}=S)
        when not is_map_key(host_offset,S) ->
    {noreply,S}; % first clock reading is still in flight
input_info({Port,{data,<<2,Qpc:64/little,_Frames:32/little,Flags:32/little,PCM/binary>>}},
           #{port := Port,host_offset := Offset}=S) ->
    try
        Input=ba_audio_input:captured(PCM,Qpc+Offset,maps:get(input,S)),
        Silent=case Flags band 2 of 0 -> 0;_ -> 1 end,
        %% 16#100: the helper re-anchored its frame->host mapping (discontinuity).
        Reanchor=case Flags band 16#100 of 0 -> 0;_ -> 1 end,
        {noreply,S#{input := Input,silent_packets => maps:get(silent_packets,S,0)+Silent,
                    clock_reanchors => maps:get(clock_reanchors,S,0)+Reanchor}}
    catch _:_ -> {noreply,fail(<<"Invalid capture buffer; toggle the audio capability off and on.">>,S)} end;
input_info({Port,{data,<<5,_Code:32/little-signed,Message/binary>>}},#{port := Port}=S) ->
    {noreply,fail(<<Message/binary,". Check Windows privacy settings for microphone access.">>,S)};
input_info({Port,{exit_status,Code}},#{port := Port}=S) ->
    {noreply,fail(iolist_to_binary(io_lib:format("Audio capture exited (~B).",[Code])),S)};
input_info({'EXIT',Port,Reason},#{port := Port}=S) ->
    {noreply,fail(iolist_to_binary(io_lib:format("Audio capture port closed: ~p",[Reason])),S)};
input_info({'DOWN',Ref,process,_,_},S) ->
    case ba_audio_input:source_monitor(Ref,maps:get(input,S)) of
        true -> {noreply,fail(<<"Audio publication closed; toggle the audio capability off and on.">>,S)};
        false -> {noreply,S}
    end;
input_info(_,S) -> {noreply,S}.

calibrate(#{port := Port}=S) ->
    Sent=erlang:monotonic_time(nanosecond),
    try port_command(Port,<<3>>) of true -> S#{request_sent => Sent}
    catch error:badarg -> fail(<<"Audio capture helper stopped.">>,S) end.

capture_start(#{port := undefined,kind := Kind}=S) ->
    case {available(),ba_audio_input:ready()} of
        {false,_} -> {reply,{error,<<"Audio capture helper is missing; rebuild the Windows app.">>},S};
        {_,{error,_}} -> {reply,{error,waiting_for_clock},S};
        {true,ok} ->
            Args=case Kind of microphone -> ["mic"];broadcast -> ["loopback",os:getpid()] end,
            try open_port({spawn_executable,helper()},[binary,{packet,4},exit_status,use_stdio,hide,
                    {env,ba_native_env:without_secrets()},{args,Args}]) of
                Port -> {reply,ok,(initial(Kind))#{permission_token => maps:get(permission_token,S,legacy),port := Port,
                                                    input := (ba_audio_input:new())#{state := starting}}}
            catch error:Reason -> {reply,{error,Reason},S} end
    end;
capture_start(S) -> {reply,ok,S}.

fail(Text,S) ->
    close_port(S),
    Input=ba_audio_input:failed(Text,maps:get(input,S)),
    (initial(maps:get(kind,S)))#{input := Input}.
close_port(#{port := undefined}) -> ok;
close_port(#{port := Port}) -> try port_close(Port) catch error:badarg -> ok end.
stop_confirmed(#{port := undefined}=S) -> {maps:get(stop_result,S,ok),S};
stop_confirmed(#{port := Port}=S) ->
    case ba_native_stop:port(Port,<<"s">>,<<6>>) of
        ok -> close_port(S),ba_audio_input:stop(maps:get(input,S)),{ok,(initial(maps:get(kind,S)))#{stop_result => ok}};
        Result -> {Result,S#{stop_result => Result}}
    end.
terminate(_,S) -> close_port(S),ba_audio_input:close(maps:get(input,S)).
format_status(Status) ->
    maps:map(fun(state,S) -> maps:with([kind],S);(log,_) -> [];(_,_) -> redacted end,Status).
