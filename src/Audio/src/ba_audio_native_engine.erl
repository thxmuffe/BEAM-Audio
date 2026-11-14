%% Shared local binding used by the libwebrtc and GStreamer native services.
%% Socket ownership stays in the supervised Erlang media session, with no proxy.
-module(ba_audio_native_engine).
-export([available/0, open/1, command/2, event/2, close/1]).

available() -> os:getenv("BA_WEBRTC_AUDIO_PORT") =/= false.
open(Options) -> case ba_device_permission:allowed(playback) of
    true -> case application:get_env(ba_core,runtime_profile,legacy_apps) of
        buffee_control -> {error,native_revocation_protocol_required};
        _ -> open_permitted(Options)
    end;false -> {error,consent_required} end.
open_permitted(#{ice_servers := ICE}) ->
    case os:getenv("BA_WEBRTC_AUDIO_PORT") of
        false -> {error, <<"Native audio output is unavailable on this device.">>};
        PortText ->
            case gen_tcp:connect({127,0,0,1}, list_to_integer(PortText),
                    [binary,{packet,4},{active,once},{packet_size,131072},
                     {send_timeout,1000},{send_timeout_close,true}], 2000) of
                {ok, Socket} ->
                    case send(Socket, #{op => <<"prepare">>, ice_servers => ICE}) of
                        ok -> {ok, Socket};
                        Error -> gen_tcp:close(Socket), Error
                    end;
                Error -> Error
            end
    end.

command(Socket, play) -> playback_send(Socket,#{op => <<"play">>});
command(Socket, pause) -> send(Socket, #{op => <<"pause">>});
command(Socket, stats) -> send(Socket, #{op => <<"stats">>});
command(Socket, {clock, Sent}) -> send(Socket, #{op => <<"clock">>, sent_ns => Sent});
command(Socket, {signal, answer, Fields}) -> send(Socket, Fields#{op => <<"answer">>});
command(Socket, {signal, candidate, Fields}) -> send(Socket, Fields#{op => <<"candidate">>});
command(Socket, {minimum_delay, Delay, Id}) ->
    Value = case Delay of automatic -> null; _ -> Delay end,
    send(Socket, #{op => <<"minimum_delay">>, delay_ms => Value, request_id => Id});
command(Socket, {presentation, Plan}) -> playback_send(Socket, #{op => <<"schedule">>, plan => Plan});
command(Socket, {rate_correction, Plan}) -> send(Socket, #{op => <<"rate">>, plan => Plan});
command(Socket, {reject_packet, Id, Reason}) -> send(Socket, #{op => <<"reject_packet">>, packet_id => Id, reason => Reason});
command(Socket, {invalidate_schedule, Reason}) -> send(Socket, #{op => <<"invalidate_schedule">>, reason => Reason});
command(_, {diagnostic_sink_slaving, resample}) -> {error,adaptive_retiming_disabled};
command(Socket, {diagnostic_sink_slaving, Method}) when Method =:= none ->
    send(Socket, #{op => <<"diagnostic_sink_slaving">>, method => atom_to_binary(Method)});
command(_, _) -> {error, unsupported_output_control}.

event(Socket, {tcp, Socket, Bytes}) ->
    ok = inet:setopts(Socket, [{active,once}]),
    {ok, json:decode(Bytes)};
event(Socket, {tcp_closed, Socket}) -> {error, native_audio_closed};
event(Socket, {tcp_error, Socket, Reason}) -> {error, {native_audio_error, Reason}};
event(_, _) -> ignore.
close(Socket) -> gen_tcp:close(Socket).
send(Socket, Message) -> gen_tcp:send(Socket, json:encode(Message)).

playback_send(Socket,Message) -> case ba_device_permission:allowed(playback) of
    true -> send(Socket,Message);false -> {error,consent_revoked} end.
