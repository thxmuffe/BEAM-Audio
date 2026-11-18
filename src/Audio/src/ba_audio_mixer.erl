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
                {message_queue_len,N} when N<64 ->
                    case ba_device_config:token(speaker) of {ok,T} -> gen_server:cast(P,{packet,Id,D,H,PCM,T});_ -> {error,consent_required} end;
                _ -> {error,mixer_mailbox_overloaded}
            end;
        _ -> {error,mixer_unavailable}
    end.
status() -> gen_server:call(ba_session_scope:ref(?MODULE),status).
clock() ->
    Module = ba_settings:app(audio_clock_adapter,ba_buffee_clock),
    try {ok,Module:id(),Module:now()} catch _:_ -> {error,clock_unavailable} end.
init([]) ->
    process_flag(trap_exit,true),
    erlang:send_after(2,self(),render),
    erlang:send_after(500,self(),observe_output),
    {ok,#{mix => undefined,descriptors => #{},device => undefined,dropped => 0,rendered => 0,submitted_frames => 0,last_error => null}}.
handle_call({revoke_permissions,_},_,S) ->
    {Result,Next}=close_confirmed(S),
    case maps:find(owner,S) of {ok,P} -> P ! {audio_output_failed,self(),consent_revoked};error -> ok end,
    {reply,Result,Next#{mix := undefined,descriptors := #{}}};
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
    Output=maps:get(output,S,#{supported => false}),
    Binding=case maps:get(device,S) of
        {_,D} -> maps:merge(Output,maps:with([mapping_round_trip_ns],D));_ -> Output
    end,
    PublicOutput=case maps:find(output_sample_at,S) of
        {ok,T} -> Binding#{stats_age_ms => max(0,now_ms()-T)};error -> Binding end,
    Meter=case {ba_audio_diagnostics:enabled(meters),maps:find(output_meter_at,S)} of
        {true,{ok,At}} -> (maps:get(output_meter,S,#{}))#{<<"meter_age_ms">> => max(0,now_ms()-At),<<"meter_stage">> => <<"output_submitted">>};
        _ -> #{}
    end,
    {reply,View#{handoff_lead_ns => maps:get(handoff_lead_ns,S,0),submitted_frames => maps:get(submitted_frames,S),output => PublicOutput,output_meter => Meter,dropped => maps:get(dropped,S),rendered => maps:get(rendered,S),last_error => maps:get(last_error,S),
        output_stop_pending => maps:get(output_stop_pending,S,false),diagnostics => ba_diagnostics:view(S)},S};
handle_call(_,_,S) -> {reply,ok,S}.
handle_cast({packet,Id,D,H,PCM,T},S) ->
    case ba_device_permission:valid(playback,T) of true -> accept_packet(Id,D,H,PCM,S);false -> {noreply,drop(stale_permission,S)} end;
handle_cast({packet,Id,D,H,PCM},S) ->
    case ba_settings:app(runtime_profile,legacy_apps) of buffee_control -> {noreply,drop(stale_permission,S)};_ -> accept_packet(Id,D,H,PCM,S) end;
handle_cast(_,S) -> {noreply,S}.
accept_packet(Id,D,H,PCM,S) ->
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
    end.
handle_info(observe_output,S) ->
    erlang:send_after(500,self(),observe_output),
    {noreply,observe_output(S)};
handle_info(render,S) ->
    Next = render(S),erlang:send_after(2,self(),render),{noreply,Next};
handle_info({'DOWN',Ref,process,_,_},#{owner_monitor := Ref} = S) ->
    {noreply,(maps:without([owner,owner_monitor],close(S)))#{mix := undefined,descriptors := #{}}};
handle_info({tcp,Socket,_}=Message,#{device := {A,#{socket := Socket}=Device}}=S) ->
    case A:event(Device,Message) of
        {dropped,Reason} -> {noreply,drop(Reason,S)};
        {diagnostics,Stats} -> {noreply,S#{output => Stats,output_sample_at => now_ms()}};
        {error,Reason} -> {noreply,output_failed(Reason,S)}
    end;
handle_info({tcp_closed,Socket},#{device := {_,#{socket := Socket}}}=S) -> {noreply,output_failed(output_closed,S)};
handle_info({tcp_error,Socket,_},#{device := {_,#{socket := Socket}}}=S) -> {noreply,output_failed(output_error,S)};
handle_info({'EXIT',Pid,normal},#{device := {ba_mac_output,#{pid := Pid}}}=S) -> {noreply,output_failed(output_closed,S#{device := undefined})};
handle_info({'EXIT',Pid,_},#{device := {_,#{pid := Pid}}}=S) -> {noreply,output_failed(output_closed,S)};
handle_info(_,S) -> {noreply,S}.
open(S) -> case ba_device_permission:allowed(playback) of
    true -> open_permitted(S);false -> {error,consent_required} end.
open_permitted(#{device := undefined,mix := Mix} = S) ->
    case {clock(),ba_settings:app(audio_output_adapter)} of
        {{ok,Clock,{ok,_}},{ok,A}} when Clock=:=map_get(clock,Mix) ->
            D = #{sample_rate => maps:get(rate,Mix),channel_count => 2,sample_format => float32_le,clock => Clock},
            case A:open(D) of {ok,Device} -> {ok,S#{device := {A,Device}}};Error -> Error end;
        _ -> {error,output_or_clock_unavailable}
    end;
open_permitted(#{output_stop_pending := true}) -> {error,native_stop_unconfirmed};
open_permitted(S) -> {ok,S}.
render(S) -> case ba_device_permission:allowed(playback) of
    true -> render_ready(16,expire_inputs(S));
    false -> (close(S))#{mix := undefined,descriptors := #{}}
end.
%% Timers are wakeups, not an audio clock: one wakeup may cover several PCM
%% blocks (notably on Windows). Drain the existing handoff window in a bounded
%% batch, preserving every target and all authorization/late-output checks.
render_ready(0,S) -> S;
render_ready(N,S) ->
    Next=render_live(S),
    case Next=:=S of true -> S;false -> render_ready(N-1,Next) end.
render_live(#{mix := Mix,device := {A,Device}} = S) when Mix=/=undefined ->
    Module = ba_settings:app(audio_clock_adapter,ba_buffee_clock),
    case {ba_audio_mix:next_time(Mix),clock()} of
        {Time,{ok,Clock,{ok,_}}} when is_integer(Time),Clock=:=map_get(clock,Mix) ->
            case Module:to_monotonic(Time) of
                {ok,Mono} ->
                    Handoff = Mono-maps:get(latency_ns,Device,0),Now = erlang:monotonic_time(nanosecond),
                    %% Queue against absolute host targets with enough lead for
                    %% a coarse OS timer plus one delayed wakeup. This changes
                    %% submission time only, never the audible presentation time.
                    case Handoff-Now=<50000000 of
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
                                ok -> submitted(PCM,Frames,Handoff-Now,S#{mix := Next,rendered := maps:get(rendered,S)+1});
                                {error,_} -> output_failed(output_write_failed,S#{mix := Next})
                            end
                    end
            end
    end.
submitted(PCM,Frames,Lead,S) ->
    Base=S#{submitted_frames := maps:get(submitted_frames,S)+Frames},
    Metered=case ba_audio_diagnostics:enabled(meters) of
        true -> Base#{output_meter => ba_audio_diagnostics:meter(float32_le,PCM),output_meter_at => now_ms()};
        false -> maps:without([output_meter,output_meter_at],Base)
    end,
    case ba_audio_diagnostics:enabled(analysis) of
        true -> Metered#{handoff_lead_ns => Lead};false -> Metered
    end.
observe_output(#{device := {A,D}}=S) ->
    %% Optional binding diagnostics: older/other outputs remain explicitly unsupported.
    case erlang:function_exported(A,diagnostics,2) of
        true ->
            try A:diagnostics(D,ba_audio_diagnostics:options()) of
                {ok,Stats} -> S#{output => Stats,output_sample_at => now_ms()};
                pending -> S;
                unsupported -> S#{output => #{supported => false}}
            catch _:_ -> S#{output => #{supported => false}} end;
        false -> S#{output => #{supported => false}}
    end;
observe_output(S) -> maps:without([output,output_sample_at,output_meter,output_meter_at],S).
%% An OS sink failing is not a failed publication or transport. Fence and flush
%% affected playback only; notify its owner to retry through normal authorization.
output_failed(Reason,S) ->
    case maps:find(owner,S) of {ok,P} -> P ! {audio_output_failed,self(),Reason};error -> ok end,
    drop(Reason,close((flush(S))#{mix := undefined,descriptors := #{},output_stop_pending => true})).

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
close(#{device := {_,_}} = S) -> {_,Next}=close_confirmed(S),Next;
close(S) -> maps:remove(output_stop_pending,S).
terminate(_,S) -> close(S),ok.
format_status(Status) ->
    maps:map(fun(state,S) -> (maps:with([dropped,rendered,last_error],S))#{diagnostics => ba_diagnostics:view(S)};
        (log,_) -> [];(_,_) -> redacted end,Status).

close_confirmed(#{device := {A,D}}=S) ->
    Result=try A:close(D) of ok -> ok;_ -> {error,native_stop_unconfirmed} catch _:_ -> {error,native_stop_unconfirmed} end,
    case Result of ok -> {ok,maps:remove(output_stop_pending,S#{device := undefined})};_ -> {Result,S} end;
close_confirmed(S) -> {ok,S}.
