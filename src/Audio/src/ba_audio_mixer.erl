%% One local output clock/device; independent input queues and explicit failures.
-module(ba_audio_mixer).
-behaviour(gen_server).
-export([start_link/0,add/3,remove/1,enable/2,gain/2,push/4,renew/2,status/0,clock/0]).
-export([init/1,handle_call/3,handle_cast/2,handle_info/2,terminate/2,format_status/1]).
start_link() -> gen_server:start_link(ba_session_scope:registration(?MODULE),?MODULE,[],[]).
add(Id,D,G) -> gen_server:call(ba_session_scope:ref(?MODULE),{add,Id,D,G}).
remove(Id) -> gen_server:call(ba_session_scope:ref(?MODULE),{remove,Id}).
enable(Id,B) -> gen_server:call(ba_session_scope:ref(?MODULE),{enable,Id,B}).
gain(Id,G) -> gen_server:call(ba_session_scope:ref(?MODULE),{gain,Id,G}).
renew(Id,Until) -> gen_server:call(ba_session_scope:ref(?MODULE),{renew,Id,Until}).
push(Id,D,H,PCM) ->
    case ba_session_scope:whereis(?MODULE) of
        P when is_pid(P) ->
            case process_info(P,message_queue_len) of
                {message_queue_len,N} when N<64 -> gen_server:cast(P,{packet,Id,D,H,PCM});
                _ -> {error,mixer_mailbox_overloaded}
            end;
        _ -> {error,mixer_unavailable}
    end.
status() -> gen_server:call(ba_session_scope:ref(?MODULE),status).
clock() ->
    Module = application:get_env(ba_core,audio_clock_adapter,ba_buffee_clock),
    try {ok,Module:id(),Module:now()} catch _:_ -> {error,clock_unavailable} end.
init([]) ->
    process_flag(trap_exit,true),
    erlang:send_after(2,self(),render),
    {ok,#{mix => undefined,descriptors => #{},device => undefined,dropped => 0,rendered => 0,last_error => null}}.
handle_call({renew,Id,Until},{Owner,_},#{owner := Owner,descriptors := Ds}=S) ->
    case maps:find(Id,Ds) of
        {ok,#{authorization_deadline := Old}=D} when Until>Old ->
            case now_ms()<Old of
                true -> {reply,ok,S#{descriptors := Ds#{Id := D#{authorization_deadline := Until}}}};
                false -> {reply,{error,authorization_expired},S}
            end;
        _ -> {reply,{error,unknown_or_unchanged_authorization},S}
    end;
handle_call({add,Id,#{sample_rate := Rate,clock := Clock} = D,G},{Owner,_},S0) ->
    S = owner(Owner,S0),
    Mix = case maps:get(mix,S) of undefined -> ba_audio_mix:new(Rate,Clock);M -> M end,
    case maps:get(rate,Mix)=:=Rate andalso maps:get(clock,Mix)=:=Clock andalso
         (map_size(maps:get(streams,Mix))<16 orelse maps:is_key(Id,maps:get(streams,Mix))) of
        true ->
            {reply,ok,S#{mix := ba_audio_mix:add(Id,G,Mix),
                         descriptors := (maps:get(descriptors,S))#{Id => D}}};
        false -> {reply,{error,unsupported_mix_rate_or_clock},S}
    end;
handle_call({remove,Id},_,#{mix := Mix,descriptors := Ds} = S) when Mix=/=undefined ->
    Next = S#{mix := ba_audio_mix:remove(Id,Mix),descriptors := maps:remove(Id,Ds)},
    case map_size(maps:get(descriptors,Next)) of
        0 -> {reply,ok,(close(Next))#{mix := undefined}};
        _ -> {reply,ok,Next}
    end;
handle_call({enable,Id,B},_,S) ->
    case maps:is_key(Id,maps:get(descriptors,S)) of
        false -> {reply,{error,unknown_subscription},S};
        true ->
            case B of
                false -> {reply,ok,S#{mix := ba_audio_mix:enable(Id,false,maps:get(mix,S))}};
                true ->
                    case open(S) of
                        {ok,Next} -> {reply,ok,Next#{mix := ba_audio_mix:enable(Id,true,maps:get(mix,Next))}};
                        Error -> {reply,Error,S}
                    end
            end
    end;
handle_call({gain,Id,G},_,S) -> {reply,ok,S#{mix := ba_audio_mix:gain(Id,G,maps:get(mix,S))}};
handle_call(status,_,S) ->
    View = case maps:get(mix,S) of undefined -> #{streams => 0,queued_blocks => 0,clipped_frames => 0};M -> ba_audio_mix:snapshot(M) end,
    {reply,View#{dropped => maps:get(dropped,S),rendered => maps:get(rendered,S),last_error => maps:get(last_error,S),diagnostics => ba_diagnostics:view(S)},S};
handle_call(_,_,S) -> {reply,ok,S}.
handle_cast({packet,Id,D,H,PCM},S) ->
    case {clock(),maps:get(mix,S)} of
        {{ok,_,{ok,Now}},Mix} when Mix=/=undefined ->
            case packet_authorized(Id,H,S) of
                true ->
                    case ba_audio_mix:push(Id,D,H,PCM,Now,Mix) of
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
handle_info({tcp_closed,Socket},#{device := {_,#{socket := Socket}}}=S) -> {noreply,output_failed(output_closed,S)};
handle_info({tcp_error,Socket,_},#{device := {_,#{socket := Socket}}}=S) -> {noreply,output_failed(output_error,S)};
handle_info({'EXIT',Pid,_},#{device := {_,#{pid := Pid}}}=S) -> {noreply,output_failed(output_closed,S)};
handle_info(_,S) -> {noreply,S}.
open(#{device := undefined,mix := Mix} = S) ->
    case {clock(),application:get_env(ba_core,audio_output_adapter)} of
        {{ok,Clock,{ok,_}},{ok,A}} when Clock=:=map_get(clock,Mix) ->
            D = #{sample_rate => maps:get(rate,Mix),channel_count => 2,sample_format => float32_le,clock => Clock},
            case A:open(D) of {ok,Device} -> {ok,S#{device := {A,Device}}};Error -> Error end;
        _ -> {error,output_or_clock_unavailable}
    end;
open(S) -> {ok,S}.
render(S) -> render_live(expire_inputs(S)).
render_live(#{mix := Mix,device := {A,Device}} = S) when Mix=/=undefined ->
    Module = application:get_env(ba_core,audio_clock_adapter,ba_buffee_clock),
    case {ba_audio_mix:next_time(Mix),clock()} of
        {Time,{ok,Clock,{ok,_}}} when is_integer(Time),Clock=:=map_get(clock,Mix) ->
            case Module:to_monotonic(Time) of
                {ok,Mono} ->
                    Handoff = Mono-maps:get(latency_ns,Device,0),Now = erlang:monotonic_time(nanosecond),
                    case Handoff-Now=<20000000 of
                        false -> S;
                        true ->
                            render_authorized(Mono,Handoff,Now,A,Device,S)
                    end;
                _ -> drop(clock_unavailable,flush(S))
            end;
        {none,_} -> S;
        _ -> drop(clock_unavailable,flush(S))
    end;
render_live(S) -> S.
render_authorized(Mono,Handoff,Now,A,Device,#{mix := Mix,descriptors := Ds}=S) ->
    Rate = maps:get(rate,Mix),
    Expired = [Id || {Id,D} <- maps:to_list(Ds),
        (maps:get(authorization_deadline,D)*1000000-Mono)*Rate div 1000000000<1],
    case Expired of
        [_|_] ->
            Next = lists:foldl(fun(Id,Acc) -> Acc#{mix := ba_audio_mix:remove(Id,maps:get(mix,Acc)),
                descriptors := maps:remove(Id,maps:get(descriptors,Acc))} end,S,Expired),
            render_live(drop(authorization_deadline,Next));
        [] ->
            Max = lists:min([256|[(maps:get(authorization_deadline,D)*1000000-Mono)*Rate div 1000000000 || D <- maps:values(Ds)]]),
            {H,PCM,Next} = ba_audio_mix:take(Max,Mix),
            case Handoff>Now of
                false -> drop(missed_packet_target,S#{mix := Next});
                true ->
                    Frames = maps:get(frame_count,H),
                    %% Platform binding consumes stereo planar float32.
                    Left = [<<L:32/little-float>> || <<L:32/little-float,_:32/little-float>> <= PCM],
                    Right = [<<R:32/little-float>> || <<_:32/little-float,R:32/little-float>> <= PCM],
                    Output = iolist_to_binary([Left,Right]),
                    case Handoff>erlang:monotonic_time(nanosecond) of
                        false -> drop(missed_packet_target,S#{mix := Next});
                        true ->
                            Result=try A:write(Device,Handoff,Frames,Output) catch exit:_ -> {error,output_closed} end,
                            case Result of
                                ok -> S#{mix := Next,rendered := maps:get(rendered,S)+1};
                                {error,_} -> output_failed(output_write_failed,S#{mix := Next})
                            end
                    end
            end
    end.
%% An OS sink failing is not a failed publication or transport. Fence and flush
%% affected playback only; notify its owner to retry through normal authorization.
output_failed(Reason,S) ->
    case maps:find(owner,S) of {ok,P} -> P ! {audio_output_failed,self(),Reason};error -> ok end,
    drop(Reason,close((flush(S))#{mix := undefined,descriptors := #{}})).

owner(Owner,#{owner := Owner} = S) -> S;
owner(Owner,S) ->
    case maps:find(owner_monitor,S) of {ok,Ref} -> demonitor(Ref,[flush]);error -> ok end,
    (close(S))#{mix := undefined,descriptors := #{},owner => Owner,owner_monitor => monitor(process,Owner)}.

%% Buffering future targets does not authorize execution after the lease.
%% render_authorized checks each actual output span against current permissions.
packet_authorized(Id,_,#{descriptors := Ds}) ->
    case maps:find(Id,Ds) of {ok,D} -> now_ms()<maps:get(authorization_deadline,D);error -> false end.
expire_inputs(#{descriptors := Ds,mix := Mix} = S) when Mix=/=undefined ->
    Now = now_ms(),Expired = [Id || {Id,D} <- maps:to_list(Ds),maps:get(authorization_deadline,D)=<Now],
    Next = lists:foldl(fun(Id,Acc) -> Acc#{mix := ba_audio_mix:remove(Id,maps:get(mix,Acc)),
        descriptors := maps:remove(Id,maps:get(descriptors,Acc)),last_error := authorization_expired} end,S,Expired),
    case map_size(maps:get(descriptors,Next)) of 0 -> (close(Next))#{mix := undefined};_ -> Next end;
expire_inputs(S) -> S.
now_ms() -> erlang:monotonic_time(millisecond).

flush(#{mix := undefined}=S) -> S;
flush(#{mix := Mix} = S) ->
    Next = maps:fold(fun(Id,I,Acc) -> ba_audio_mix:enable(Id,maps:get(enabled,I),Acc) end,Mix,maps:get(streams,Mix)),S#{mix := Next}.
drop(R,S) -> ba_diagnostics:count(R,S#{dropped := maps:get(dropped,S)+1,last_error := R}).
close(#{device := {A,D}} = S) -> try A:close(D) catch exit:_ -> ok end,S#{device := undefined};
close(S) -> S.
terminate(_,S) -> close(S),ok.
format_status(Status) ->
    maps:map(fun(state,S) -> (maps:with([dropped,rendered,last_error],S))#{diagnostics => ba_diagnostics:view(S)};
        (log,_) -> [];(_,_) -> redacted end,Status).
