%% Bounded, payload-free projection of existing local audio/clock observations.
%% Cached by the Device Handler; remote reads never poll the audio processes.
-module(ba_audio_diagnostics).
-export([snapshot/2,validate/1,trace/1,validate_trace/1,meters/1,validate_meters/1,options/0,configure/1,configure/2,validate_options/1,enabled/1]).
%% Inspection follows the user's calibration consent; there are no separate
%% switches. Calibrate speaker covers received/output levels and playback
%% analysis; Calibrate microphone covers capture levels. Never changes audio
%% consent, packet targets or mandatory failure accounting.
options() ->
    Speaker=allowed(calibrate_speaker),
    #{<<"meters">> => Speaker,<<"analysis">> => Speaker,<<"microphone">> => allowed(calibrate_microphone)}.
enabled(microphone) -> allowed(calibrate_microphone);
enabled(meters) -> allowed(calibrate_speaker);
enabled(analysis) -> allowed(calibrate_speaker).
allowed(Key) -> try ba_device_permission:allowed(Key) catch _:_ -> false end.
validate_options(P) ->
    true=is_map(P) andalso map_size(P)>0 andalso map_size(P)=<2,
    maps:foreach(fun(K,V) -> true=lists:member(K,[<<"meters">>,<<"analysis">>]),true=is_boolean(V) end,P),ok.
%% A request to inspect (any true option) asks for calibration consent on this
%% Device; Ask policies raise a request its user answers. Turning inspection
%% off is the user's own Settings choice, not a remote command.
configure(P) -> configure(P,<<"local">>).
configure(P,From) ->
    ok=validate_options(P),
    case lists:member(true,maps:values(P)) of
        true -> [ba_device_request:approve(K,From) || K <- [calibrate_speaker,calibrate_microphone]];
        false -> ok
    end,
    {ok,options()}.
-define(MAX_INT,9007199254740991).
snapshot(Audio,Clock) ->
    Flags=#{<<"diagnostics.meters">> => enabled(meters),<<"diagnostics.analysis">> => enabled(analysis)},
    case enabled(analysis) of false -> Flags;true -> maps:merge(Flags,project(Audio,Clock)) end.
project(Audio,Clock) ->
    Subs=maps:values(maps:get(subscriptions,Audio,#{})),
    Transports=[T || R <- Subs++maps:get(provider_status,Audio,[]),
        T <- [maps:get(transport,R,#{})],map_size(T)>0],
    Mixer=maps:get(mixer,Audio,#{}),
    Base=#{<<"sampled_at_ms">> => erlang:system_time(millisecond),
        <<"receiver.subscriptions">> => length(Subs),<<"transport.media">> => length(Transports),
        <<"transport.open">> => length([ok || #{open := true} <- Transports]),
        <<"receiver.active_subscriptions">> => length([ok || #{state := active} <- Subs]),
        <<"receiver.mix_ready_subscriptions">> => length([ok || #{mix_ready := true} <- Subs])},
    R=fields(<<"receiver">>,[rejected,publications,suspended],Audio,Base),
    M=fields(<<"mixer">>,[dropped,rendered,queued_blocks,queued_bytes,clipped_frames,streams,output_stop_pending,submitted_frames,handoff_lead_ns,
        max_wakeup_gap_ms,long_wakeup_gaps],Mixer,R),
    N=fields(<<"output">>,[supported,engine_running,player_running,scheduled_frames,completed_frames,queued_buffers,rejected_buffers,completion_age_ms,lead_min_ns,lead_max_ns,sample_rate,channels,latency_ns,volume_milli,route,backend,stats_age_ms,mapping_round_trip_ns,
        silence_frames,clock_reanchors],maps:get(output,Mixer,#{}),M),
    C=fields(<<"clock">>,[state,last_error,offset_error,age_ns,round_trip_ns,remaining_correction_ns,
        filter_ready,filter_sample_count,filter_required_samples,filter_reset_count,filter_reset_reason,sample_gaps,last_sample_gap_ms,
        estimate_quality,raw_offset_ns,initial_sync_complete,initial_sync_samples,initial_sync_round_trip_ns],Clock,N),
    O=fields(<<"clock">>,[offset_ms,ready],maps:get(offset_policy,Clock,#{}),C),
    T=lists:foldl(fun(View,Acc) ->
        lists:foldl(fun(K,A) ->
            case maps:find(K,View) of
                {ok,V} when is_integer(V),V>=0 -> Key=key(<<"transport">>,K),A#{Key => maps:get(Key,A,0)+V};
                _ -> A
            end
        end,Acc,[received,sent,rejected])
    end,O,Transports),
    T2=lists:foldl(fun setup_fields/2,T,Transports),
    D1=failures(<<"receiver">>,maps:get(diagnostics,Audio,#{}),T2),
    D2=failures(<<"mixer">>,maps:get(diagnostics,Mixer,#{}),D1),
    Counts=lists:foldl(fun(View,Acc) -> maps:fold(fun(K,V,A) -> A#{K => maps:get(K,A,0)+V} end,
        Acc,maps:get(counts,maps:get(diagnostics,View,#{}),#{})) end,#{},Transports),
    Result=failures(<<"transport">>,#{counts => Counts},D2),
    Filtered=maps:filter(fun field_scalar/2,Result),
    %% Reserve three fields for switches and cache age; preserve summaries before capped reasons.
    {Failures,Summary}=lists:partition(fun({K,_}) -> binary:match(K,<<".failure.">>)=/=nomatch end,maps:to_list(Filtered)),
    maps:from_list(Summary++lists:sublist(lists:sort(Failures),max(0,125-length(Summary)))).
%% Connection setup of current transports: how many sit at each step, the
%% candidate types exchanged (never addresses) and configured STUN/TURN URL counts.
setup_fields(#{setup := Setup},Acc) when is_map(Setup) ->
    Add=fun(Key,N,A) -> A#{Key => maps:get(Key,A,0)+N} end,
    A1=case maps:get(stage,Setup,undefined) of
        Stage when is_atom(Stage),Stage=/=undefined -> Add(key(<<"transport.stage">>,Stage),1,Acc);
        _ -> Acc
    end,
    A2=lists:foldl(fun(Side,A) ->
        maps:fold(fun(Type,N,B) when is_atom(Type),is_integer(N) -> Add(key(<<"transport.",(atom_to_binary(Side))/binary,"_candidates">>,Type),N,B);
                     (_,_,B) -> B end,A,maps:get(Side,Setup,#{}))
    end,A1,[local,remote]),
    lists:foldl(fun(K,A) ->
        case maps:find(K,Setup) of
            {ok,N} when is_integer(N) -> Key=key(<<"transport.ice">>,K),A#{Key => max(N,maps:get(Key,A,0))};
            _ -> A
        end
    end,A2,[stun_urls,turn_urls]);
setup_fields(_,Acc) -> Acc.
meters(Audio) ->
    case enabled(meters) of
        false -> #{};
        true ->
            Pairs=[{<<"receive_max">>,maps:get(receive_meter,Audio,#{})},
                {<<"output_submitted">>,maps:get(output_meter,maps:get(mixer,Audio,#{}),#{})}],
            maps:from_list([{K,V} || {K,V} <- Pairs,maps:is_key(<<"peak_db">>,V)])
    end.
validate_meters(M) ->
    true=is_map(M) andalso map_size(M)=<2,
    maps:foreach(fun(K,E) ->
        true=lists:member(K,[<<"receive_max">>,<<"output_submitted">>]),
        true=is_map(E) andalso lists:sort(maps:keys(E))=:=[<<"meter_age_ms">>,<<"meter_stage">>,<<"peak_db">>,<<"rms_db">>],
        K=maps:get(<<"meter_stage">>,E),
        [begin V=maps:get(F,E),true=is_number(V) andalso V>= -96 andalso V=<48 end || F <- [<<"peak_db">>,<<"rms_db">>]],
        Age=maps:get(<<"meter_age_ms">>,E),true=is_integer(Age) andalso Age>=0 andalso scalar(Age)
    end,M),ok.
trace(Audio) ->
    case enabled(analysis) of
        false -> #{};
        true ->
            Mixer=maps:get(mixer,Audio,#{}),
            Transports=[maps:get(transport,R,#{}) || R <- maps:values(maps:get(subscriptions,Audio,#{}))++maps:get(provider_status,Audio,[])],
            Views=[{receiver,Audio},{mixer,Mixer}]++[{transport,T} || T <- Transports],
            Now=erlang:monotonic_time(millisecond),
            Events=[#{<<"stage">> => atom_to_binary(Stage),<<"reason">> => atom_to_binary(Reason),<<"age_ms">> => max(0,Now-At)} ||
                {Stage,View} <- Views,#{at_ms := At,reason := Reason} <- maps:get(trace,maps:get(diagnostics,View,#{}),[]),scalar(atom_to_binary(Reason))],
            Recent=lists:sublist(lists:sort(fun(A,B) -> maps:get(<<"age_ms">>,A)<maps:get(<<"age_ms">>,B) end,Events),16),
            maps:from_list(lists:zip([integer_to_binary(N) || N <- lists:seq(1,length(Recent))],Recent))
    end.
validate_trace(Events) ->
    true=is_map(Events) andalso map_size(Events)=<16,
    true=lists:sort(maps:keys(Events))=:=lists:sort([integer_to_binary(N) || N <- lists:seq(1,map_size(Events))]),
    lists:foreach(fun(E) ->
        true=is_map(E) andalso lists:sort(maps:keys(E))=:=[<<"age_ms">>,<<"reason">>,<<"stage">>],
        true=lists:member(maps:get(<<"stage">>,E),[<<"receiver">>,<<"mixer">>,<<"transport">>]),
        true=scalar(maps:get(<<"reason">>,E)),true=is_binary(maps:get(<<"reason">>,E)),
        Age=maps:get(<<"age_ms">>,E),true=is_integer(Age) andalso Age>=0 andalso scalar(Age)
    end,maps:values(Events)),ok.
fields(Prefix,Keys,View,Acc) -> lists:foldl(fun(K,A) ->
    case maps:find(K,View) of {ok,V} -> A#{key(Prefix,K) => wire(V)};error -> A end
end,Acc,Keys).
key(Prefix,K) -> <<Prefix/binary,".",(atom_to_binary(K))/binary>>.
wire(V) when is_atom(V),V=/=true,V=/=false -> atom_to_binary(V);
wire(V) -> V.
failures(Prefix,D,Acc) ->
    WithLast=case maps:get(last_error,D,null) of
        null -> Acc;
        Reason when is_atom(Reason) -> Acc#{key(Prefix,last_error) => atom_to_binary(Reason)}
    end,
    lists:foldl(fun({K,V},A) ->
        Name=atom_to_binary(K),A#{<<Prefix/binary,".failure.",Name/binary>> => V}
    end,WithLast,lists:sublist(lists:sort(maps:to_list(maps:get(counts,D,#{}))),32)).
scalar(V) when is_integer(V) -> abs(V)=< ?MAX_INT;
scalar(V) when is_boolean(V) -> true;
scalar(V) when is_binary(V),byte_size(V)>0,byte_size(V)=<64 ->
    re:run(V,<<"^[a-z][a-z0-9_]*$">>,[{capture,none}])=:=match;
scalar(_) -> false.
field_scalar(<<"clock.raw_offset_ns">>,V) ->
    try _=ba_session_time_protocol:integer(V),true catch _:_ -> false end;
field_scalar(_,V) -> scalar(V).
validate(D) ->
    true=is_map(D) andalso map_size(D)=<128,
    maps:foreach(fun(K,V) ->
        true=is_binary(K) andalso byte_size(K)=<96,
        true=re:run(K,<<"^(sampled_at_ms|(?:receiver|mixer|transport|clock|diagnostics|output)\\.[a-z][a-z0-9_]*(?:\\.[a-z][a-z0-9_]*)?)$">>,[{capture,none}])=:=match,
        true=field_scalar(K,V)
    end,D),ok.
