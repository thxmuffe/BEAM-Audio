%% Legacy supervised output: PCM conversion and execution of Erlang deadlines.
-module(ba_audio_output).
-behaviour(gen_server).
-export([start_link/3, push/3, stop/1, available/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

available() -> application:get_env(ba_core, audio_output_adapter) =/= undefined.
start_link(Owner, Descriptor, Adapter) -> gen_server:start_link(?MODULE, {Owner, Descriptor, Adapter}, []).
push(Pid, Header, PCM) -> gen_server:cast(Pid, {packet, Header, PCM}).
stop(Pid) -> try gen_server:stop(Pid) catch exit:_ -> ok end.

init({Owner, D, Adapter}) ->
    monitor(process, Owner), self() ! open,
    {ok, #{owner => Owner, descriptor => D, adapter => Adapter, device => undefined,
           scheduled => 0, dropped => 0, last_end => undefined, last_summary => undefined}}.
handle_call({revoke_permissions,_},_,#{adapter := A,device := D}=S) ->
    Result=case D of undefined -> ok;_ -> try A:close(D) catch _:_ -> {error,native_stop_unconfirmed} end end,
    {stop,normal,Result,S#{device := undefined}};
handle_call(_, _, S) -> {reply, {error, unsupported_request}, S}.
handle_info(open, #{adapter := A, descriptor := D} = S) ->
    case maps:get(clock, D) =:= ba_buffee_clock:id() of
        false -> {stop, unsupported_clock, S};
        true ->
            case A:open(D) of
                {ok, Device} ->
                    Next = S#{device := Device}, notify(playing, Next),
                    {noreply, Next};
                {error, Reason} -> {stop, {output_open_failed, Reason}, S}
            end
    end;
handle_info({'DOWN', _, process, _, _}, S) -> {stop, normal, S};
handle_info({tcp_closed, _}, S) -> {stop, output_closed, S};
handle_info({tcp_error, _, Reason}, S) -> {stop, {output_error, Reason}, S};
handle_info(_, S) -> {noreply, S}.

handle_cast({packet, #{playback_time := Time, frame_count := Frames}, PCM},
            #{device := Device, adapter := A, descriptor := D, last_end := Last} = S)
        when Device =/= undefined ->
    Rate = maps:get(sample_rate, D),
    case ba_buffee_clock:to_monotonic(Time) of
        {ok, Mono} ->
            Render = Mono - maps:get(latency_ns, Device),
            Now = erlang:monotonic_time(nanosecond),
            %% One-frame tolerance accounts for integer timestamp rounding.
            Ordered = Last =:= undefined orelse Mono >= Last - 1000000000 div Rate,
            case Ordered andalso Render > Now andalso Render - Now =< 1000000000 of
                true ->
                    Planes = planar_float(PCM, maps:get(sample_format,D), maps:get(channel_count,D)),
                    case A:write(Device, Render, Frames, Planes) of
                        ok ->
                            Next = S#{scheduled := maps:get(scheduled,S)+1,
                                      last_end := Mono + Frames*1000000000 div Rate},
                            {noreply, summary(Next)};
                        {error, Reason} -> {stop, {output_write_failed, Reason}, S}
                    end;
                false -> drop(S)
            end;
        _ -> drop(S)
    end;
handle_cast(_, S) -> drop(S).
drop(S) -> Next = S#{dropped := maps:get(dropped,S)+1}, {noreply, summary(Next)}.
%% Send summaries once a second, rather than one UI event per buffer.
summary(S) ->
    Second = erlang:monotonic_time(second),
    case maps:get(last_summary,S) of
        Second -> S;
        _ -> notify(playing, S), S#{last_summary := Second}
    end.
notify(State, #{owner := Owner, device := Device} = S) ->
    Owner ! {ba_audio_output, self(), #{state => atom_to_binary(State),
        scheduled => maps:get(scheduled,S), dropped => maps:get(dropped,S),
        latency_ms => maps:get(latency_ns,Device)/1000000}}.
terminate(_, #{adapter := A, device := Device}) ->
    case Device of undefined -> ok; _ -> A:close(Device) end.

%% OS buffer layout is planar float32; source packets keep their original format.
planar_float(PCM, Format, Channels) ->
    Samples = samples(PCM, Format),
    Planes = lists:foldl(fun({Index, Value}, Acc) ->
        C = Index rem Channels, Acc#{C := [<<Value:32/little-float>> | maps:get(C,Acc)]}
    end, maps:from_list([{C,[]} || C <- lists:seq(0,Channels-1)]),
         lists:zip(lists:seq(0,length(Samples)-1), Samples)),
    iolist_to_binary([lists:reverse(maps:get(C,Planes)) || C <- lists:seq(0,Channels-1)]).
samples(PCM, float32_le) -> [V || <<V:32/little-float>> <= PCM];
samples(PCM, pcm16_le) -> [V/32768 || <<V:16/little-signed>> <= PCM];
samples(PCM, pcm24_le) -> [V/8388608 || <<V:24/little-signed>> <= PCM];
samples(PCM, pcm32_le) -> [V/2147483648 || <<V:32/little-signed>> <= PCM].
