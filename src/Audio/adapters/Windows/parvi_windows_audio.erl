%% Node-local audio input owns its native port independently of the window.
-module(parvi_windows_audio).
-behaviour(gen_server).
-export([start/0, stop/0, status/0, start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

start() ->
    case supervisor:start_child(parvi_windows_sup,
            #{id => audio_input, start => {?MODULE, start_link, []}}) of
        {ok, _} -> gen_server:call(?MODULE, start);
        {error, {already_started, _}} -> gen_server:call(?MODULE, start);
        Error -> Error
    end.
stop() -> gen_server:call(?MODULE, stop).
status() -> case whereis(?MODULE) of undefined -> #{state => stopped}; _ -> gen_server:call(?MODULE, status) end.
start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).
init([]) -> {ok, #{state => stopped, port => undefined}}.
handle_call(start, _, #{port := undefined} = S) ->
    Root = filename:dirname(filename:dirname(code:which(?MODULE))),
    try open_port({spawn_executable, filename:join(Root, "parvi_audio_input.exe")},
                  [binary, {packet, 4}, exit_status, use_stdio, hide]) of
        Port -> {reply, ok, #{state => starting, port => Port}}
    catch error:Reason -> {reply, {error, Reason}, S#{state := error, error => <<"Build parvi_audio_input.exe first.">>}} end;
handle_call(start, _, S) -> {reply, ok, S};
handle_call(stop, _, S) ->
    close(S), {reply, ok, #{state => stopped, port => undefined}};
handle_call(status, _, S) -> {reply, maps:without([port, accumulator], S), S}.
handle_cast(_, S) -> {noreply, S}.
handle_info({Port, {data, <<1, Size:32/little, Wave:Size/binary, Name/binary>>}}, #{port := Port} = S) ->
    try format(Wave) of
        #{rate := Rate, channels := Channels} = Format ->
            port_command(Port, <<$r>>),
            erlang:send_after(100, self(), {report, Port}),
            Meter = (parvi_audio_meter:levels(parvi_audio_meter:new()))#{
                <<"source">> => unicode:characters_to_binary(Name, {utf16, little}),
                <<"rate">> => Rate, <<"channels">> => Channels, <<"frames">> => 0,
                <<"discontinuities">> => 0},
            {noreply, S#{state := running, format => Format, meter => Meter,
                         accumulator => parvi_audio_meter:new()}}
    catch error:_ ->
        close(S), {noreply, S#{state := error, port := undefined, error => <<"Unsupported Windows PCM format.">>}}
    end;
handle_info({Port, {data, <<2, Frames:32/little, Flags:32/little,
                           Position:64/little, QPC:64/little, Bytes/binary>>}},
            #{port := Port, format := #{encoding := Encoding, align := Align},
              meter := Meter, accumulator := Acc} = S) ->
    Data = case Flags band 2 of 0 -> Bytes; _ -> binary:copy(<<0>>, Frames * Align) end,
    true = byte_size(Data) =:= Frames * Align,
    Next = Meter#{<<"frames">> := maps:get(<<"frames">>, Meter) + Frames,
                  <<"discontinuities">> := maps:get(<<"discontinuities">>, Meter) + (Flags band 1)},
    {noreply, S#{meter := Next, device_position => Position, capture_qpc_100ns => QPC,
                 capture_flags => Flags, accumulator := parvi_audio_meter:accumulate(Encoding, Data, Acc)}};
handle_info({Port, {data, <<3, Code:32/little>>}}, #{port := Port} = S) ->
    Error = io_lib:format("WASAPI input failed (0x~8.16.0B). Check the default output, then stop/start input.", [Code]),
    {noreply, S#{state := error, error => iolist_to_binary(Error)}};
handle_info({Port, {data, <<4>>}}, #{port := Port, state := running} = S) ->
    erlang:send_after(10, self(), {read, Port}), {noreply, S};
handle_info({read, Port}, #{port := Port, state := running} = S) ->
    port_command(Port, <<$r>>), {noreply, S};
handle_info({report, Port}, #{port := Port, state := running, accumulator := Acc, meter := Meter} = S) ->
    erlang:send_after(100, self(), {report, Port}),
    {noreply, S#{meter := maps:merge(Meter, parvi_audio_meter:levels(Acc)),
                 accumulator := parvi_audio_meter:new()}};
handle_info({Port, {exit_status, Code}}, #{port := Port} = S) ->
    {noreply, S#{port := undefined, state := error,
                error => maps:get(error, S, iolist_to_binary(io_lib:format("Audio input stopped (~B). Start to reconnect.", [Code])))}};
handle_info(_, S) -> {noreply, S}.
terminate(_, S) -> close(S).
close(#{port := undefined}) -> ok;
close(#{port := Port}) -> try port_close(Port) catch error:badarg -> ok end, ok.

%% WAVEFORMATEX/WAVEFORMATEXTENSIBLE are Windows structures, not our network format.
format(<<Tag:16/little, Channels:16/little, Rate:32/little, _:32,
         Align:16/little, Bits:16/little, _:16, Extra/binary>>) ->
    Type = case Tag of
        16#fffe ->
            <<_:16, _:32, Subtype:32/little, 0:16, 16#10:16/little,
              16#80, 0, 0, 16#aa, 0, 16#38, 16#9b, 16#71>> = Extra,
            Subtype;
        _ -> Tag
    end,
    Encoding = case {Type, Bits} of
        {3, 32} -> float32_le; {1, 16} -> pcm16_le;
        {1, 24} -> pcm24_le; {1, 32} -> pcm32_le
    end,
    true = Channels > 0 andalso Rate > 0 andalso Align =:= Channels * (Bits div 8),
    #{encoding => Encoding, rate => Rate, channels => Channels, align => Align}.
