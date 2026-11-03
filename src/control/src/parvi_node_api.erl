%% Named runtime commands over ordinary admitted OTP connections. No UI dependency.
-module(parvi_node_api).
-export([request/1, members/0, invitation/1]).

%% An existing member can introduce a receiver to an indirect source. The desk
%% still authenticates that connection using its already-installed membership.
invitation(Name) -> remote(Name,parvi_cluster_desk,invitation,[],5000).

request(#{<<"op">> := <<"nodes">>}) -> {ok,#{nodes => members()}};
request(#{<<"op">> := <<"inspect">>, <<"node">> := Node}) ->
    remote(Node,parvi_node_diagnostics,snapshot,[],1000);
request(#{<<"op">> := <<"clock">>, <<"node">> := Node}) ->
    case remote(Node,parvi_clock,status,[],1000) of
        {ok,Clock} -> {ok,maps:with([state,role,master,timeline,master_instance,coverage,revision,
                                   remaining_correction_ns,interval_ms,age_ns,requests_served,offset_ns,
                                   slew_ppm,round_trip_ns,measurement_uncertainty_ns,
                                   upstream_acquisitions,master_revision,filtered_utc_time,filtered_offset_ns,
                                   filter_ready,filter_sample_count,filter_required_samples,
                                   sample_interval_ms,threshold_ns],Clock)};
        Error -> Error
    end;
request(#{<<"op">> := <<"sources">>, <<"node">> := Node}) ->
    case remote(Node,parvi_audio_receiver,snapshot,[],1000) of
        {ok,Snapshot} -> {ok,maps:with([offers],Snapshot)};
        Error -> Error
    end;
request(#{<<"op">> := <<"refresh_sources">>, <<"node">> := Node}) ->
    call(Node,parvi_audio_receiver,refresh,[]);
request(#{<<"op">> := <<"capture">>, <<"node">> := Node}) ->
    case remote(Node,parvi_mac_opus_audio,status,[],1000) of
        {ok,Snapshot} -> {ok,maps:with([state,frames,blocks,dropped_callbacks,handler,format,timeline,capture_timing,skipped_frames,send_errors],Snapshot)};
        Error -> Error
    end;
request(#{<<"op">> := <<"subscribe">>, <<"node">> := Node, <<"source_id">> := Id,
          <<"profile">> := <<"channel">>}) -> call(Node,parvi_audio_receiver,subscribe,[Id,channel]);
request(#{<<"op">> := <<"play">>, <<"node">> := Node}) -> call(Node,parvi_audio_receiver,playback,[start]);
request(#{<<"op">> := <<"pause">>, <<"node">> := Node}) -> call(Node,parvi_audio_receiver,playback,[stop]);
request(#{<<"op">> := <<"unsubscribe">>, <<"node">> := Node}) -> call(Node,parvi_audio_receiver,stop,[]);
request(#{<<"op">> := <<"minimum_delay">>, <<"node">> := Node, <<"delay_ms">> := null}) ->
    call(Node,parvi_audio_receiver,minimum_playout_delay,[automatic]);
request(#{<<"op">> := <<"minimum_delay">>, <<"node">> := Node, <<"delay_ms">> := Delay})
        when is_integer(Delay), Delay >= 0, Delay =< 10000 ->
    call(Node,parvi_audio_receiver,minimum_playout_delay,[Delay]);
request(#{<<"op">> := <<"broadcast_start">>, <<"node">> := Node}) -> call(Node,parvi_mac_opus_audio,start,[]);
request(#{<<"op">> := <<"broadcast_stop">>, <<"node">> := Node}) -> call(Node,parvi_mac_opus_audio,stop,[]);
request(_) -> {error,<<"Unsupported node command or invalid arguments.">>}.

members() ->
    Names = case parvi_cluster_trust:policy() of
        #{<<"members">> := Members} -> [maps:get(<<"node">>,M) || M <- maps:values(Members)];
        _ -> [atom_to_binary(node())]
    end,
    Online = [atom_to_binary(N) || N <- [node() | nodes()]],
    [#{node => N, connected => lists:member(N,Online)} || N <- lists:usort(Names)].

call(Name,Module,Function,Args) -> remote(Name,Module,Function,Args,5000).
remote(Name,Module,Function,Args,Timeout) when is_binary(Name) ->
    case lists:any(fun(#{node := N}) -> N =:= Name end,members()) of
        true ->
            try locate(Name) of
                offline -> {error,<<"Node has no connected route from this inspector.">>};
                Route ->
                    try execute(Route,Module,Function,Args,Timeout) of
                        {error,_} = Error -> Error;
                        {ok,Value} -> {ok,Value};
                        Value -> {ok,Value}
                    catch
                        error:{erpc,timeout} -> {error,<<"Node command timed out.">>};
                        error:_ -> {error,<<"Node command unavailable; check connection and app versions.">>}
                    end
            catch error:_ -> {error,<<"Node route unavailable.">>} end;
        false -> {error,<<"Node is not a member of this cluster.">>}
    end.

%% Distribution is deliberately not a full mesh. Use one already-connected
%% member as a relay; each hop is ordinary OTP erpc, with no new transport.
locate(Name) ->
    case [N || N <- [node() | nodes()], atom_to_binary(N) =:= Name] of
        [Node] -> {direct,Node};
        [] -> locate_peer(Name,nodes())
    end.
locate_peer(_,[]) -> offline;
locate_peer(Name,[Peer | Rest]) ->
    Peers = try erpc:call(Peer,erlang,nodes,[],1000) catch _:_ -> [] end,
    case [N || N <- Peers, atom_to_binary(N) =:= Name] of
        [Node] -> {via,Peer,Node};
        [] -> locate_peer(Name,Rest)
    end.
execute({direct,Node},Module,Function,Args,Timeout) ->
    erpc:call(Node,Module,Function,Args,Timeout);
execute({via,Peer,Node},Module,Function,Args,Timeout) ->
    erpc:call(Peer,erpc,call,[Node,Module,Function,Args,Timeout],Timeout+1000).
