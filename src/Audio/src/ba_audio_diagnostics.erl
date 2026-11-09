%% Bounded, payload-free projection of existing local audio/clock observations.
%% Cached by the Device Handler; remote reads never poll the audio processes.
-module(ba_audio_diagnostics).
-export([snapshot/2,validate/1]).
-define(MAX_INT,9007199254740991).
snapshot(Audio,Clock) ->
    Subs=maps:values(maps:get(subscriptions,Audio,#{})),
    Transports=[maps:get(transport,R,#{}) || R <- Subs++maps:get(provider_status,Audio,[])],
    Mixer=maps:get(mixer,Audio,#{}),
    Base=#{<<"sampled_at_ms">> => erlang:system_time(millisecond),
        <<"receiver.subscriptions">> => length(Subs),<<"transport.sessions">> => length(Transports)},
    R=fields(<<"receiver">>,[rejected,publications],Audio,Base),
    M=fields(<<"mixer">>,[dropped,rendered,queued_blocks,queued_bytes,clipped_frames,streams],Mixer,R),
    C=fields(<<"clock">>,[state,last_error,age_ns,round_trip_ns,remaining_correction_ns,filter_sample_count,filter_required_samples],Clock,M),
    O=fields(<<"clock">>,[offset_ms,ready],maps:get(offset_policy,Clock,#{}),C),
    T=lists:foldl(fun(View,Acc) ->
        lists:foldl(fun(K,A) ->
            case maps:find(K,View) of
                {ok,V} when is_integer(V),V>=0 -> Key=key(<<"transport">>,K),A#{Key => maps:get(Key,A,0)+V};
                _ -> A
            end
        end,Acc,[received,sent,rejected])
    end,O,Transports),
    D1=failures(<<"receiver">>,maps:get(diagnostics,Audio,#{}),T),
    D2=failures(<<"mixer">>,maps:get(diagnostics,Mixer,#{}),D1),
    Counts=lists:foldl(fun(View,Acc) -> maps:fold(fun(K,V,A) -> A#{K => maps:get(K,A,0)+V} end,
        Acc,maps:get(counts,maps:get(diagnostics,View,#{}),#{})) end,#{},Transports),
    Result=failures(<<"transport">>,#{counts => Counts},D2),
    maps:filter(fun(_,V) -> scalar(V) end,Result).
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
validate(D) ->
    true=is_map(D) andalso map_size(D)=<128,
    maps:foreach(fun(K,V) ->
        true=is_binary(K) andalso byte_size(K)=<96,
        true=re:run(K,<<"^(sampled_at_ms|(?:receiver|mixer|transport|clock)\\.[a-z][a-z0-9_]*(?:\\.[a-z][a-z0-9_]*)?)$">>,[{capture,none}])=:=match,
        true=scalar(V)
    end,D),ok.
