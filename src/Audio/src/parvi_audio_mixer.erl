%% One local output clock/device; independent input queues and explicit failures.
-module(parvi_audio_mixer).
-behaviour(gen_server).
-export([start_link/0,add/3,remove/1,enable/2,gain/2,push/4,status/0,clock/0]).
-export([init/1,handle_call/3,handle_cast/2,handle_info/2,terminate/2]).
start_link() -> gen_server:start_link({local,?MODULE},?MODULE,[],[]).
add(Id,D,G) -> gen_server:call(?MODULE,{add,Id,D,G}).
remove(Id) -> gen_server:call(?MODULE,{remove,Id}).
enable(Id,B) -> gen_server:call(?MODULE,{enable,Id,B}).
gain(Id,G) -> gen_server:call(?MODULE,{gain,Id,G}).
push(Id,D,H,PCM) ->
    case process_info(whereis(?MODULE),message_queue_len) of
        {message_queue_len,N} when N<64 -> gen_server:cast(?MODULE,{packet,Id,D,H,PCM});
        _ -> {error,overloaded}
    end.
status() -> gen_server:call(?MODULE,status).
clock() ->
    Module = application:get_env(parvi,audio_clock_adapter,parvi_clock),
    try {ok,Module:id(),Module:now()} catch _:_ -> {error,clock_unavailable} end.
init([]) ->
    erlang:send_after(2,self(),render),
    {ok,#{mix => undefined,descriptors => #{},device => undefined,dropped => 0,rendered => 0,last_error => null}}.
handle_call({add,Id,#{sample_rate := Rate,clock := Clock} = D,G},{Owner,_},S0) ->
    S = owner(Owner,S0),
    Mix = case maps:get(mix,S) of undefined -> parvi_audio_mix:new(Rate,Clock);M -> M end,
    case maps:get(rate,Mix)=:=Rate andalso maps:get(clock,Mix)=:=Clock andalso
         (map_size(maps:get(streams,Mix))<16 orelse maps:is_key(Id,maps:get(streams,Mix))) of
        true ->
            {reply,ok,S#{mix := parvi_audio_mix:add(Id,G,Mix),
                         descriptors := (maps:get(descriptors,S))#{Id => D}}};
        false -> {reply,{error,unsupported_mix_rate_or_clock},S}
    end;
handle_call({remove,Id},_,#{mix := Mix,descriptors := Ds} = S) when Mix=/=undefined ->
    Next = S#{mix := parvi_audio_mix:remove(Id,Mix),descriptors := maps:remove(Id,Ds)},
    case map_size(maps:get(descriptors,Next)) of
        0 -> {reply,ok,(close(Next))#{mix := undefined}};
        _ -> {reply,ok,Next}
    end;
handle_call({enable,Id,B},_,S) ->
    case maps:is_key(Id,maps:get(descriptors,S)) of
        false -> {reply,{error,unknown_subscription},S};
        true ->
            case B of
                false -> {reply,ok,S#{mix := parvi_audio_mix:enable(Id,false,maps:get(mix,S))}};
                true ->
                    case open(S) of
                        {ok,Next} -> {reply,ok,Next#{mix := parvi_audio_mix:enable(Id,true,maps:get(mix,Next))}};
                        Error -> {reply,Error,S}
                    end
            end
    end;
handle_call({gain,Id,G},_,S) -> {reply,ok,S#{mix := parvi_audio_mix:gain(Id,G,maps:get(mix,S))}};
handle_call(status,_,S) ->
    View = case maps:get(mix,S) of undefined -> #{streams => 0,queued_blocks => 0,clipped_frames => 0};M -> parvi_audio_mix:snapshot(M) end,
    {reply,View#{dropped => maps:get(dropped,S),rendered => maps:get(rendered,S),last_error => maps:get(last_error,S)},S};
handle_call(_,_,S) -> {reply,ok,S}.
handle_cast({packet,Id,D,H,PCM},S) ->
    case {clock(),maps:get(mix,S)} of
        {{ok,_,{ok,Now}},Mix} when Mix=/=undefined ->
            case packet_authorized(Id,H,S) of
                true ->
                    case parvi_audio_mix:push(Id,D,H,PCM,Now,Mix) of
                        {ok,Next} -> {noreply,S#{mix := Next}};
                        {error,R,_} -> {noreply,drop(R,S)}
                    end;
                false -> {noreply,drop(authorization_deadline,S)}
            end;
        _ -> {noreply,drop(clock_unavailable,S)}
    end;
handle_cast(_,S) -> {noreply,S}.
handle_info(render,S) ->
    Next = render(S),erlang:send_after(2,self(),render),{noreply,Next};
handle_info({'DOWN',Ref,process,_,_},#{owner_monitor := Ref} = S) ->
    {noreply,(maps:without([owner,owner_monitor],close(S)))#{mix := undefined,descriptors := #{}}};
handle_info({tcp_closed,_},S) -> {stop,output_closed,S};
handle_info({tcp_error,_,Reason},S) -> {stop,{output_error,Reason},S};
handle_info(_,S) -> {noreply,S}.
open(#{device := undefined,mix := Mix} = S) ->
    case {clock(),application:get_env(parvi,audio_output_adapter)} of
        {{ok,Clock,{ok,_}},{ok,A}} when Clock=:=map_get(clock,Mix) ->
            D = #{sample_rate => maps:get(rate,Mix),channel_count => 2,sample_format => float32_le,clock => Clock},
            case A:open(D) of {ok,Device} -> {ok,S#{device := {A,Device}}};Error -> Error end;
        _ -> {error,output_or_clock_unavailable}
    end;
open(S) -> {ok,S}.
render(S) -> render_live(expire_inputs(S)).
render_live(#{mix := Mix,device := {A,Device}} = S) when Mix=/=undefined ->
    Module = application:get_env(parvi,audio_clock_adapter,parvi_clock),
    case {parvi_audio_mix:next_time(Mix),clock()} of
        {Time,{ok,Clock,{ok,_}}} when is_integer(Time),Clock=:=map_get(clock,Mix) ->
            case Module:to_monotonic(Time) of
                {ok,Mono} ->
                    Handoff = Mono-maps:get(latency_ns,Device,0),Now = erlang:monotonic_time(nanosecond),
                    case Handoff-Now=<20000000 of
                        false -> S;
                        true ->
                            {H,PCM,Next} = parvi_audio_mix:take(256,Mix),
                            case Handoff>Now of
                                false -> drop(missed_packet_target,S#{mix := Next});
                                true ->
                                    Frames = maps:get(frame_count,H),
                                    %% Platform binding consumes stereo planar float32.
                                    Left = [<<L:32/little-float>> || <<L:32/little-float,_:32/little-float>> <= PCM],
                                    Right = [<<R:32/little-float>> || <<_:32/little-float,R:32/little-float>> <= PCM],
                                    case A:write(Device,Handoff,Frames,iolist_to_binary([Left,Right])) of
                                        ok -> S#{mix := Next,rendered := maps:get(rendered,S)+1};
                                        {error,R} -> exit({output_write_failed,R})
                                    end
                            end
                    end;
                _ -> drop(clock_unavailable,flush(S))
            end;
        {none,_} -> S;
        _ -> drop(clock_unavailable,flush(S))
    end;
render_live(S) -> S.
owner(Owner,#{owner := Owner} = S) -> S;
owner(Owner,S) ->
    case maps:find(owner_monitor,S) of {ok,Ref} -> demonitor(Ref,[flush]);error -> ok end,
    (close(S))#{mix := undefined,descriptors := #{},owner => Owner,owner_monitor => monitor(process,Owner)}.

packet_authorized(Id,#{playback_time := Time,frame_count := Frames},#{descriptors := Ds}) ->
    try
        D = maps:get(Id,Ds),Deadline = maps:get(authorization_deadline,D),
        Module = application:get_env(parvi,audio_clock_adapter,parvi_clock),
        {ok,End} = Module:to_monotonic(Time+Frames*1000000000 div maps:get(sample_rate,D)),
        now_ms()<Deadline andalso End=<Deadline*1000000
    catch _:_ -> false end;
packet_authorized(_,_,_) -> false.
expire_inputs(#{descriptors := Ds,mix := Mix} = S) when Mix=/=undefined ->
    Now = now_ms(),Expired = [Id || {Id,D} <- maps:to_list(Ds),maps:get(authorization_deadline,D)=<Now],
    Next = lists:foldl(fun(Id,Acc) -> Acc#{mix := parvi_audio_mix:remove(Id,maps:get(mix,Acc)),
        descriptors := maps:remove(Id,maps:get(descriptors,Acc)),last_error := authorization_expired} end,S,Expired),
    case map_size(maps:get(descriptors,Next)) of 0 -> (close(Next))#{mix := undefined};_ -> Next end;
expire_inputs(S) -> S.
now_ms() -> erlang:monotonic_time(millisecond).

flush(#{mix := Mix} = S) ->
    Next = maps:fold(fun(Id,I,Acc) -> parvi_audio_mix:enable(Id,maps:get(enabled,I),Acc) end,Mix,maps:get(streams,Mix)),S#{mix := Next}.
drop(R,S) -> S#{dropped := maps:get(dropped,S)+1,last_error := R}.
close(#{device := {A,D}} = S) -> A:close(D),S#{device := undefined};
close(S) -> S.
terminate(_,S) -> close(S),ok.
