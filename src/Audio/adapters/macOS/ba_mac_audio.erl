%% Mac input adapter: port lifetime, Core Audio buffers and host-clock mapping.
%% Portable publication/meter/timing policy is delegated to ba_audio_input.
-module(ba_mac_audio).
-behaviour(gen_server).
-export([start/0, stop/0, status/0, available/0, start_link/0,start/1,stop/1,status/1,start_link/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,format_status/1]).

available() -> case helper() of false -> false; Path -> filelib:is_regular(Path) end.
helper() -> os:getenv("BA_MAC_AUDIO_HELPER").
helper(broadcast) -> helper();
helper(microphone) -> helper().
name(broadcast) -> ?MODULE;
name(microphone) -> ba_mac_microphone.
start() -> start(broadcast).
start(Kind) ->
    case ba_audio_sup:ensure_started() of
        ok ->
            case supervisor:start_child(ba_session_scope:ref(ba_audio_sup),
                    #{id => name(Kind), start => {?MODULE, start_link, [Kind]}, restart => temporary}) of
                {ok, Pid} -> gen_server:call(Pid, start);
                {error, {already_started, Pid}} -> gen_server:call(Pid, start);
                Error -> Error
            end;
        Error -> Error
    end.
stop() -> stop(broadcast).
stop(Kind) -> case ba_session_scope:whereis(name(Kind)) of undefined -> ok; Pid -> gen_server:call(Pid, stop) end.
status() -> status(broadcast).
status(Kind) ->
    case ba_session_scope:whereis(name(Kind)) of
        undefined -> #{state => stopped, available => helper(Kind)=/=false};
        Pid -> gen_server:call(Pid, status)
    end.
start_link() -> start_link(broadcast).
start_link(Kind) -> gen_server:start_link(ba_session_scope:registration(name(Kind)),?MODULE,Kind,[]).
init(Kind) -> process_flag(trap_exit, true), {ok, initial(Kind)}.
initial(Kind) -> #{kind => Kind,port => undefined, input => ba_audio_input:new(), dropped_callbacks => 0}.

handle_call({revoke_permissions,_},_,S) -> {Result,Next}=stop_confirmed(S),{reply,Result,Next};
handle_call(start,From,#{kind := Kind}=S) ->
    case ba_device_permission:allowed(Kind) of
        true -> case ba_device_permission:enter(Kind) of {ok,T} -> capture_start(From,S#{permission_token => T});E -> {reply,E,S} end;false -> {reply,{error,consent_required},S}
    end;
handle_call(stop,_,S) -> {Result,Next}=stop_confirmed(S),{reply,Result,Next};
handle_call(status, _, S) ->
    Diagnostics = maps:without([port, input, request_sent, host_offset, best_round_trip], S),
    Public = maps:merge(Diagnostics, ba_audio_input:status(maps:get(input, S))),
    {reply, Public#{available => available()}, S};
handle_call(_, _, S) -> {reply, {error, unsupported_request}, S}.
handle_cast(_, S) -> {noreply, S}.

handle_info(Message,S) ->
    case maps:get(port,S,undefined)=/=undefined andalso not ba_device_permission:valid(maps:get(kind,S),maps:get(permission_token,S,legacy)) of
        true -> case maps:get(stop_result,S,undefined) of undefined -> {_,Next}=stop_confirmed(S),{noreply,Next};_ -> {noreply,S} end;
        false -> input_info(Message,S)
    end.
input_info({Port, {data, <<1, Metadata/binary>>}}, #{port := Port} = S) ->
    try ba_core_audio:format(Metadata) of
        #{rate := Rate, channels := Channels, encoding := Encoding} = Format ->
            Descriptor = #{encoding => pcm, sample_format => Encoding, sample_rate => Rate,
                           channel_count => Channels},
            {Name,Key}=case maps:get(kind,S) of broadcast -> {<<"Mac default output">>,<<"default-output">>};microphone -> {<<"Mac microphone">>,<<"microphone">>} end,
            Input = ba_audio_input:open(Name, Descriptor,Key),
            {noreply, read(S#{input := Input, format => Format})}
    catch _:_ -> {noreply, fail(<<"Unsupported Core Audio PCM format or source unavailable.">>, S)} end;
input_info({Port, {data, <<5, Host:64/little>>}},
            #{port := Port, request_sent := Sent, format := Format} = S) ->
    Now = erlang:monotonic_time(nanosecond), RTT = Now - Sent,
    Next = case RTT < maps:get(best_round_trip, S, RTT + 1) of
        true -> S#{host_offset => (Sent + Now) div 2 - ba_core_audio:host_ns(Host, Format),
                   best_round_trip => RTT, capture_clock_uncertainty_ns => RTT div 2};
        false -> S
    end,
    {noreply, Next};
input_info({Port, {data, <<2, Host:64/little, PositionBytes:8/binary,
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
    catch _:_ -> {noreply, fail(<<"Invalid capture buffers/timestamp; toggle the audio capability off and on.">>, S)} end;
input_info({Port, {data, <<4>>}}, #{port := Port} = S) ->
    erlang:send_after(10, self(), {read, Port}), {noreply, S};
input_info({read, Port}, #{port := Port} = S) -> {noreply, read(S)};
input_info({Port, {data, <<3, Code:32/little-signed, Context/binary>>}}, #{port := Port} = S) ->
    Text = iolist_to_binary(io_lib:format("~ts (Core Audio ~B).", [Context, Code])),
    {noreply, fail(Text, S)};
input_info({Port, {exit_status, Code}}, #{port := Port} = S) ->
    {noreply, fail(iolist_to_binary(io_lib:format("Audio capture exited (~B); check macOS System Audio Recording permission.", [Code])), S)};
input_info({'EXIT', Port, Reason}, #{port := Port} = S) ->
    {noreply, fail(iolist_to_binary(io_lib:format("Audio capture port closed: ~p", [Reason])), S)};
input_info({'DOWN', Ref, process, _, _}, S) ->
    case ba_audio_input:source_monitor(Ref, maps:get(input, S)) of
        true -> {noreply, fail(<<"Audio publication closed; toggle the audio capability off and on.">>, S)};
        false -> {noreply, S}
    end;
input_info(_, S) -> {noreply, S}.

read(#{port := Port} = S) ->
    Sent = erlang:monotonic_time(nanosecond),
    true = port_command(Port, <<$r>>), S#{request_sent => Sent}.

fail(Text, S) ->
    close_port(S),
    Input = ba_audio_input:failed(Text, maps:get(input, S)),
    (initial(maps:get(kind,S)))#{input := Input}.
close_port(#{port := undefined}) -> ok;
close_port(#{port := Port}) ->
    try port_close(Port) catch error:badarg -> ok end.
terminate(_, S) -> close_port(S), ba_audio_input:close(maps:get(input, S)).

format_status(Status) ->
    maps:map(fun(state,S) -> maps:with([kind,dropped_callbacks],S);
        (log,_) -> [];(_,_) -> redacted end,Status).

capture_start( _, #{port := undefined,kind := Kind} = S) ->
    case {helper(Kind)=/=false andalso filelib:is_regular(helper(Kind)), ba_audio_input:ready()} of
        {false, _} -> {reply, {error, <<"Mac audio helper is unavailable; rebuild the Mac app (macOS 14.2+).">>}, S};
        {_, {error, _}} -> {reply, {error,waiting_for_clock}, S};
        {true, ok} ->
            try open_port({spawn_executable, helper(Kind)}, [binary, {packet, 4}, exit_status, use_stdio,{env,ba_native_env:without_secrets()},{args,case Kind of microphone -> ["mic"];broadcast -> [] end}]) of
                Port -> {reply, ok, (initial(Kind))#{permission_token => maps:get(permission_token,S,legacy),port := Port, input := (ba_audio_input:new())#{state := starting}}}
            catch error:Reason -> {reply, {error, Reason}, S} end
    end;
capture_start( _, S) -> {reply, ok, S}.

stop_confirmed(#{port := undefined}=S) -> {maps:get(stop_result,S,ok),S};
stop_confirmed(#{port := Resource}=S) ->
    Result=ba_native_stop:port(Resource,<<$s>>,<<6>>),
    case Result of
        ok -> close_port(S),ba_audio_input:stop(maps:get(input,S)),{ok,(initial(maps:get(kind,S)))#{stop_result => ok}};
        _ -> {Result,S#{stop_result => Result}}
    end.
