%% Mac input adapter: port lifetime, Core Audio buffers and host-clock mapping.
%% Portable publication/meter/timing policy is delegated to ba_audio_input.
-module(ba_mac_audio).
-behaviour(gen_server).
-export([start/0, stop/0, status/0, available/0, start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

available() -> case helper() of false -> false; Path -> filelib:is_regular(Path) end.
helper() -> os:getenv("BA_MAC_AUDIO_HELPER").
start() ->
    case ba_audio_sup:ensure_started() of
        ok ->
            case supervisor:start_child(ba_audio_sup,
                    #{id => mac_audio, start => {?MODULE, start_link, []}, restart => temporary}) of
                {ok, Pid} -> gen_server:call(Pid, start);
                {error, {already_started, Pid}} -> gen_server:call(Pid, start);
                Error -> Error
            end;
        Error -> Error
    end.
stop() -> case whereis(?MODULE) of undefined -> ok; Pid -> gen_server:call(Pid, stop) end.
status() ->
    case whereis(?MODULE) of
        undefined -> #{state => stopped, available => available()};
        Pid -> gen_server:call(Pid, status)
    end.
start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).
init([]) -> process_flag(trap_exit, true), {ok, initial()}.
initial() -> #{port => undefined, input => ba_audio_input:new(), dropped_callbacks => 0}.

handle_call(start, _, #{port := undefined} = S) ->
    case {available(), ba_audio_input:ready()} of
        {false, _} -> {reply, {error, <<"Mac audio helper is unavailable; rebuild the Mac app (macOS 14.2+).">>}, S};
        {_, {error, _} = Error} -> {reply, Error, S};
        {true, ok} ->
            try open_port({spawn_executable, helper()}, [binary, {packet, 4}, exit_status, use_stdio]) of
                Port -> {reply, ok, (initial())#{port := Port, input := (ba_audio_input:new())#{state := starting}}}
            catch error:Reason -> {reply, {error, Reason}, S} end
    end;
handle_call(start, _, S) -> {reply, ok, S};
handle_call(stop, _, S) ->
    close_port(S),
    ba_audio_input:stop(maps:get(input, S)),
    {reply, ok, initial()};
handle_call(status, _, S) ->
    Diagnostics = maps:without([port, input, request_sent, host_offset, best_round_trip], S),
    Public = maps:merge(Diagnostics, ba_audio_input:status(maps:get(input, S))),
    {reply, Public#{available => available()}, S};
handle_call(_, _, S) -> {reply, {error, unsupported_request}, S}.
handle_cast(_, S) -> {noreply, S}.

handle_info({Port, {data, <<1, Metadata/binary>>}}, #{port := Port} = S) ->
    try ba_core_audio:format(Metadata) of
        #{rate := Rate, channels := Channels, encoding := Encoding} = Format ->
            Descriptor = #{encoding => pcm, sample_format => Encoding, sample_rate => Rate,
                           channel_count => Channels},
            Input = ba_audio_input:open(<<"Mac default output">>, Descriptor),
            {noreply, read(S#{input := Input, format => Format})}
    catch _:_ -> {noreply, fail(<<"Unsupported Core Audio PCM format or source unavailable.">>, S)} end;
handle_info({Port, {data, <<5, Host:64/little>>}},
            #{port := Port, request_sent := Sent, format := Format} = S) ->
    Now = erlang:monotonic_time(nanosecond), RTT = Now - Sent,
    Next = case RTT < maps:get(best_round_trip, S, RTT + 1) of
        true -> S#{host_offset => (Sent + Now) div 2 - ba_core_audio:host_ns(Host, Format),
                   best_round_trip => RTT, capture_clock_uncertainty_ns => RTT div 2};
        false -> S
    end,
    {noreply, Next};
handle_info({Port, {data, <<2, Host:64/little, PositionBytes:8/binary,
                           Dropped:64/little, Flags:32/little, Buffers/binary>>}},
            #{port := Port, format := Format, host_offset := Offset} = S) ->
    try
        true = Flags band 2 =/= 0,
        Position = case {Flags band 1, PositionBytes} of
            {1, <<P:64/little-float>>} -> P;
            _ -> undefined
        end,
        {PCM, _Frames} = ba_core_audio:samples(Buffers, Format),
        Mono = ba_core_audio:host_ns(Host, Format) + Offset,
        Input = ba_audio_input:captured(PCM, Mono, maps:get(input, S)),
        {noreply, S#{input := Input, capture_position => Position, dropped_callbacks := Dropped}}
    catch _:_ -> {noreply, fail(<<"Invalid capture buffers/timestamp; stop/start broadcast.">>, S)} end;
handle_info({Port, {data, <<4>>}}, #{port := Port} = S) ->
    erlang:send_after(10, self(), {read, Port}), {noreply, S};
handle_info({read, Port}, #{port := Port} = S) -> {noreply, read(S)};
handle_info({Port, {data, <<3, Code:32/little-signed, Context/binary>>}}, #{port := Port} = S) ->
    Text = iolist_to_binary(io_lib:format("~ts (Core Audio ~B).", [Context, Code])),
    {noreply, fail(Text, S)};
handle_info({Port, {exit_status, Code}}, #{port := Port} = S) ->
    {noreply, fail(iolist_to_binary(io_lib:format("Audio capture exited (~B); check macOS System Audio Recording permission.", [Code])), S)};
handle_info({'EXIT', Port, Reason}, #{port := Port} = S) ->
    {noreply, fail(iolist_to_binary(io_lib:format("Audio capture port closed: ~p", [Reason])), S)};
handle_info({'DOWN', Ref, process, _, _}, S) ->
    case ba_audio_input:source_monitor(Ref, maps:get(input, S)) of
        true -> {noreply, fail(<<"Audio publication closed; stop/start broadcast.">>, S)};
        false -> {noreply, S}
    end;
handle_info(_, S) -> {noreply, S}.

read(#{port := Port} = S) ->
    Sent = erlang:monotonic_time(nanosecond),
    true = port_command(Port, <<$r>>), S#{request_sent => Sent}.

fail(Text, S) ->
    close_port(S),
    Input = ba_audio_input:failed(Text, maps:get(input, S)),
    (initial())#{input := Input}.
close_port(#{port := undefined}) -> ok;
close_port(#{port := Port}) ->
    try port_close(Port) catch error:badarg -> ok end.
terminate(_, S) -> close_port(S), ba_audio_input:close(maps:get(input, S)).
