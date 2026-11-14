%% Local binary buffer/OS-clock binding. No network-audio or scheduling policy.
-module(ba_ios_audio).
-export([open/1, write/4, close/1]).
open(D) -> case ba_device_permission:allowed(playback) of
    true -> case ba_device_permission:enter(playback) of
        {ok,T} -> case permitted_open(D) of {ok,H} -> {ok,H#{permission_token => T}};E -> E end;E -> E end;false -> {error,consent_required} end.
write(D,T,F,PCM) -> case ba_device_permission:valid(playback,maps:get(permission_token,D,legacy)) of
    true -> permitted_write(D,T,F,PCM);false -> {error,consent_revoked} end.
permitted_open(#{sample_rate := Rate, channel_count := Channels}) when Channels =< 2 ->
    Port = list_to_integer(os:getenv("BA_AUDIO_PORT")),
    case gen_tcp:connect({127,0,0,1}, Port,
            [binary, {packet,4}, {active,false}, {send_timeout,1000}, {send_timeout_close,true}], 2000) of
        {ok, Socket} ->
            ok = gen_tcp:send(Socket, <<1,Rate:32,Channels:16>>),
            case gen_tcp:recv(Socket, 0, 3000) of
                {ok, <<1>>} -> calibrate(Socket);
                Other -> gen_tcp:close(Socket), {error, {native_output, Other}}
            end;
        Error -> Error
    end;
permitted_open(_) -> {error, only_mono_stereo_output_supported}.
permitted_write(#{socket := Socket, host_offset := Offset}, Mono, Frames, PCM) ->
    gen_tcp:send(Socket, <<2,(Mono+Offset):64,Frames:32,PCM/binary>>).
close(#{socket := Socket}) ->
    Result=ba_native_stop:socket(Socket,<<4>>,<<4>>),
    case Result of ok -> gen_tcp:close(Socket);_ -> ok end,Result.

calibrate(Socket) ->
    Sent = erlang:monotonic_time(nanosecond),
    ok = gen_tcp:send(Socket, <<3>>),
    case gen_tcp:recv(Socket, 0, 1000) of
        {ok, <<3,Host:64,Latency:64>>} ->
            Now = erlang:monotonic_time(nanosecond),
            ok = inet:setopts(Socket, [{active,once}]),
            {ok, #{socket => Socket, host_offset => Host-(Sent+Now) div 2, latency_ns => Latency}};
        Other -> gen_tcp:close(Socket), {error, {clock_mapping, Other}}
    end.
