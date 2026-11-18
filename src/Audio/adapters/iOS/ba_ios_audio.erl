%% Local binary buffer/OS-clock binding. No network-audio or scheduling policy.
-module(ba_ios_audio).
-export([open/1, write/4, close/1, event/2, diagnostics/2]).
open(D) -> case ba_device_permission:allowed(playback) of
    true -> case ba_device_permission:enter(playback) of
        {ok,T} -> case permitted_open(D) of {ok,H} -> {ok,H#{permission_token => T}};E -> E end;E -> E end;false -> {error,consent_required} end.
write(D,T,F,PCM) -> case ba_device_permission:valid(playback,maps:get(permission_token,D,legacy)) of
    true -> permitted_write(D,T,F,PCM);false -> {error,consent_revoked} end.
permitted_open(#{sample_rate := Rate, channel_count := Channels}) when Channels =< 2 ->
    Port = list_to_integer(ba_settings:env("BA_AUDIO_PORT")),
    case gen_tcp:connect({127,0,0,1}, Port,
            [binary, {packet,4}, {active,false}, {nodelay,true}, {send_timeout,1000}, {send_timeout_close,true}], 2000) of
        {ok, Socket} ->
            ok = gen_tcp:send(Socket, <<1,Rate:32,Channels:16>>),
            case gen_tcp:recv(Socket, 0, 3000) of
                {ok, <<1>>} -> calibrate(Socket,false,false,Port);
                {ok, <<1,1>>} -> calibrate(Socket,true,false,Port);
                {ok, <<1,2>>} -> calibrate(Socket,true,true,Port);
                {ok, <<1,3>>} -> calibrate(Socket,true,true,Port);
                Other -> gen_tcp:close(Socket), {error, {native_output, Other}}
            end;
        Error -> Error
    end;
permitted_open(_) -> {error, only_mono_stereo_output_supported}.
permitted_write(#{socket := Socket, host_offset := Offset}, Mono, Frames, PCM) ->
    gen_tcp:send(Socket, <<2,(Mono+Offset):64,Frames:32,PCM/binary>>).
diagnostics(#{socket := Socket,diagnostics_supported := true},#{<<"analysis">> := Enabled}) ->
    Flag=case Enabled of true -> 1;false -> 0 end,
    ok=gen_tcp:send(Socket,<<6,Flag>>),
    case Enabled of true -> ok=gen_tcp:send(Socket,<<7>>),pending;false -> {ok,#{supported => true,backend => ios}} end;
diagnostics(_,_) -> unsupported.
%% Rejected buffers do not destroy the binding or change subsequent targets.
event(#{socket := Socket}, {tcp,Socket,<<5,1,Late:64>>}) ->
    ok=inet:setopts(Socket,[{active,once}]),{dropped,native_late_packet,Late};
event(#{socket := Socket}, {tcp,Socket,<<5,Code>>}) ->
    Result=case Code of
        1 -> native_late_packet;
        2 -> native_target_out_of_bounds;
        3 -> native_output_queue_full;
        _ -> native_output_protocol
    end,
    case Result of
        native_output_protocol -> {error,Result};
        _ -> ok=inet:setopts(Socket,[{active,once}]),{dropped,Result}
    end;
event(#{socket := Socket}, {tcp,Socket,<<7,Engine,Player,Route,Volume:16,
        Rate:32,Channels:16,Latency:64,Scheduled:64,Completed:64,Queued:32,Rejected:64,
        CompletionAge:64,LeadMin:64,LeadMax:64>>}) when Engine=<1,Player=<1,Route=<4,Volume=<1000,Channels=<2 ->
    ok=inet:setopts(Socket,[{active,once}]),
    {diagnostics,#{supported => true,backend => ios,engine_running => Engine=:=1,player_running => Player=:=1,
        route => case Route of 1 -> speaker;2 -> receiver;3 -> external;_ -> unavailable end,
        volume_milli => Volume,sample_rate => Rate,channels => Channels,latency_ns => Latency,
        scheduled_frames => Scheduled,completed_frames => Completed,queued_buffers => Queued,
        rejected_buffers => Rejected,completion_age_ms => CompletionAge,lead_min_ns => LeadMin,lead_max_ns => LeadMax}};
event(#{socket := Socket}, {tcp,Socket,_}) -> {error,native_output_protocol}.
close(#{socket := Socket}=D) ->
    Result=ba_native_stop:socket(Socket,<<4>>,<<4>>),
    gen_tcp:close(Socket),
    case {Result,maps:get(stop_barrier,D,false)} of
        {ok,_} -> ok;
        {_,true} -> confirm_stopped(maps:get(control_port,D));
        _ -> Result
    end.

%% iOS serves output connections serially. A stop ACK on a fresh connection
%% proves the previous engine finished cleanup before the listener accepted it.
%% EOF on the old socket alone still proves nothing. Older bindings stay fenced.
confirm_stopped(Port) ->
    case gen_tcp:connect({127,0,0,1},Port,
            [binary,{packet,4},{active,false},{nodelay,true},{send_timeout,1000},{send_timeout_close,true}],1000) of
        {ok,Socket} ->
            try ba_native_stop:socket(Socket,<<4>>,<<4>>) after gen_tcp:close(Socket) end;
        _ -> {error,native_stop_unconfirmed}
    end.

calibrate(Socket,Supported,StopBarrier,Port) ->
    Sent = erlang:monotonic_time(nanosecond),
    ok = gen_tcp:send(Socket, <<3>>),
    case gen_tcp:recv(Socket, 0, 1000) of
        {ok, <<3,Host:64,Latency:64>>} ->
            Now = erlang:monotonic_time(nanosecond),
            ok = inet:setopts(Socket, [{active,once}]),
            case Supported of
                true -> Flag=case ba_audio_diagnostics:enabled(analysis) of true -> 1;false -> 0 end,
                    ok=gen_tcp:send(Socket,<<6,Flag>>);
                false -> ok
            end,
            {ok, #{socket => Socket, host_offset => Host-(Sent+Now) div 2, latency_ns => Latency,
                diagnostics_supported => Supported,stop_barrier => StopBarrier,control_port => Port,mapping_round_trip_ns => Now-Sent}};
        Other -> gen_tcp:close(Socket), {error, {clock_mapping, Other}}
    end.
