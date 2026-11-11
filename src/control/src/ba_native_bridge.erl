%% Historical trusted-app/Distributed Erlang path; not the secure Swarm API.
%% Mac JSON boundary for one native trust domain. No swarm routing or liveness worker.
-module(ba_native_bridge).
-export([request/1]).

request(JSON) ->
    Reply = try
        Request = json:decode(JSON),
        Result = command(Request),
        Response = case Result of
            status -> snapshot();
            {ok, Data} -> (snapshot())#{error => null, result => Data};
            ok -> (snapshot())#{error => null};
            {error, Reason} -> (snapshot())#{error => error_text(Reason)}
        end,
        maps:merge(Response, maps:with([<<"request_id">>], Request))
    catch
        _:_ -> (snapshot())#{error => <<"Native operation unavailable. Check runtime status; restart for a fresh session.">>}
    end,
    iolist_to_binary(json:encode(Reply)).

command(#{<<"method">> := <<"snapshot">>}) -> status;
command(#{<<"method">> := <<"node_diagnostics">>, <<"node">> := Node}) -> ba_node_diagnostics:read(Node);
command(#{<<"method">> := <<"subscribe_audio">>, <<"source_id">> := Id, <<"profile">> := Profile}) ->
    case {ba_legacy_cluster_trust:policy(), Profile} of
        {#{<<"cluster">> := _}, <<"channel">>} -> ba_audio_receiver:subscribe(Id, channel);
        {#{<<"cluster">> := _}, <<"point">>} -> ba_audio_receiver:subscribe(Id, point);
        _ -> {error, <<"Join a cluster and select an available audio profile.">>}
    end;
command(#{<<"method">> := <<"suspend_audio">>}) -> ba_audio_receiver:suspend();
command(#{<<"method">> := <<"resume_audio">>}) -> ba_audio_receiver:resume();
command(#{<<"method">> := <<"network_changed">>}) -> ba_legacy_cluster_desk:network_changed();
command(#{<<"method">> := <<"refresh_audio_sources">>}) -> ba_audio_receiver:refresh();
command(#{<<"method">> := <<"stop_audio_subscription">>}) -> ba_audio_receiver:stop();
command(#{<<"method">> := <<"start_audio_output">>}) -> ba_audio_receiver:playback(start);
command(#{<<"method">> := <<"stop_audio_output">>}) -> ba_audio_receiver:playback(stop);
command(#{<<"method">> := <<"set_audio_minimum_playout_delay">>, <<"delay_ms">> := Text}) ->
    case minimum_delay(Text) of
        {ok,Delay} -> ba_audio_receiver:minimum_playout_delay(Delay);
        Error -> Error
    end;
command(#{<<"method">> := <<"broadcast_default_output">>, <<"handler">> := <<"webrtc_audio_opus">>}) ->
    case ba_legacy_cluster_trust:policy() of
        #{<<"cluster">> := _} -> ba_mac_audio:stop(), ba_mac_opus_audio:start();
        _ -> {error, <<"Create or join a cluster before broadcasting.">>}
    end;
command(#{<<"method">> := <<"broadcast_default_output">>}) ->
    case ba_legacy_cluster_trust:policy() of
        #{<<"cluster">> := _} -> ba_mac_opus_audio:stop(), ba_mac_audio:start();
        _ -> {error, <<"Create or join a cluster before broadcasting.">>}
    end;
command(#{<<"method">> := <<"stop_broadcast">>}) -> ba_mac_opus_audio:stop(), ba_mac_audio:stop();
command(#{<<"method">> := <<"set_audio_presentation_delay">>, <<"delay_ms">> := Value}) ->
    try binary_to_integer(Value) of
        Delay -> ba_legacy_cluster_trust:set_audio_sync_delay(Delay)
    catch error:badarg -> {error, <<"Response time must be 5-30000 ms.">>} end;
command(#{<<"method">> := <<"create_swarm">>}) ->
    case ba_legacy_cluster_desk:create() of
        {ok, #{<<"cluster">> := Id}} -> {ok, #{swarm_id => Id}};
        Error -> Error
    end;
command(#{<<"method">> := <<"join_swarm">>, <<"invitation">> := Link}) ->
    case ba_legacy_cluster_desk:join(Link) of
        ok -> {ok, #{notice => <<"Invitation submitted; waiting for native admission and connection.">>}};
        Error -> Error
    end;
command(#{<<"method">> := <<"send_swarm">>, <<"swarm_id">> := Id, <<"text">> := Text}) ->
    case ba_legacy_cluster_trust:policy() of
        #{<<"cluster">> := Id} ->
            case ba_runtime:send(Text) of {ok, _} -> ok; Error -> Error end;
        _ -> {error, not_a_member}
    end;
command(#{<<"method">> := <<"remove_both">>, <<"swarm_id">> := Id, <<"target">> := Target}) ->
    case ba_legacy_cluster_trust:policy() of
        #{<<"cluster">> := Id, <<"members">> := Members} ->
            case [Key || {Key, #{<<"node">> := Name}} <- maps:to_list(Members), Name =:= Target] of
                [Key] ->
                    case ba_legacy_cluster_trust:remove_both(Key) of
                        {ok, complete} -> ok;
                        {ok, _} -> {ok, #{notice => <<"Local access retired; remote removal completion is unconfirmed.">>}};
                        Error -> Error
                    end;
                _ -> {error, not_a_member}
            end;
        _ -> {error, not_a_member}
    end;
command(#{<<"method">> := <<"leave_swarm">>}) ->
    %% Local forget: other members retain their membership records.
    ba_legacy_cluster_desk:forget();
command(#{<<"method">> := <<"configure_desk">>}) ->
    {error, <<"This native increment uses the global Render desk. Restart to begin a fresh session.">>};
command(_) -> {error, <<"Unsupported native request.">>}.

minimum_delay(<<"automatic">>) -> {ok,automatic};
minimum_delay(Text) ->
    Value = try binary_to_integer(Text) catch error:badarg -> invalid end,
    case Value of
        N when is_integer(N), N >= 0, N =< 10000 -> {ok,N};
        _ -> {error,<<"Minimum buffering must be 0-10000 ms, or automatic.">>}
    end.

snapshot() ->
    #{policy := Policy, event := Event, last_rejection := Rejection} = ba_legacy_cluster_desk:status(),
    #{chat_nodes := ChatNodes} = ba_runtime:status(),
    Messages = [message(M) || M <- ba_runtime:history()],
    Known = case Policy of
        #{<<"members">> := Members} -> lists:usort([maps:get(<<"node">>, M) || M <- maps:values(Members)]);
        _ -> [atom_to_binary(node())]
    end,
    Online = [atom_to_binary(N) || N <- ChatNodes],
    Swarms = case Policy of
        #{<<"cluster">> := Id} ->
            Invitation = case ba_legacy_cluster_desk:invitation() of {ok, Link} -> Link; _ -> null end,
            [#{id => Id, name => <<"Native cluster">>, invitation => Invitation,
               members => Known, messages => Messages}];
        _ -> []
    end,
    Clock = clock_snapshot(),
    ErrorEvent = case {Event,Rejection} of
        {{channel_stopped,_,{shutdown,unauthorized}},R} when R =/= null -> {rejected,R};
        _ -> Event
    end,
    #{node => atom_to_binary(node()), native_cluster => true, error => event_error(ErrorEvent,Policy), clock => Clock,
      audio => audio_snapshot(),
      audio_receive => ba_audio_receiver:snapshot(),
      relay => ba_relay:status(),
      direct => #{enabled => true, peers => [atom_to_binary(N) || N <- nodes()]},
      connection_string => null, known_nodes => [],
      %% Remembered permission is distinct from OTP-observed liveness.
      network => #{nodes => [#{id => N, state => case lists:member(N, Online) of
                                   true -> <<"running">>; false -> <<"offline">> end,
                               detail => <<"cluster_membership">>} || N <- Known],
                   edges => [[atom_to_binary(node()), atom_to_binary(N)] || N <- nodes()]},
      swarms => Swarms,
      runtime_info => iolist_to_binary(io_lib:format("OTP ~s / ERTS ~s / native WebRTC / clock ~s (~s), master ~s / ~p",
          [erlang:system_info(otp_release), erlang:system_info(version),
           maps:get(state,Clock), maps:get(role,Clock), maps:get(master,Clock), Event])),
      peers => [atom_to_binary(N) || N <- ChatNodes, N =/= node()], messages => Messages}.

clock_snapshot() ->
    D = ba_swarm_clock:status(),
    #{state => atom_to_binary(maps:get(state,D)), role => atom_to_binary(maps:get(role,D,waiting)),
      master => atom_to_binary(maps:get(master,D,undefined)),
      coverage => atom_to_binary(maps:get(coverage,D,unknown)),
      timeline => clock_value(timeline,D), master_instance => clock_value(master_instance,D),
      revision => maps:get(revision,D,0),
      interval_ms => maps:get(interval_ms,D,30000),
      remaining_correction_ns => maps:get(remaining_correction_ns,D,0),
      requests_served => maps:get(requests_served,D,0),
      upstream_acquisitions => maps:get(upstream_acquisitions,D,0)}.

clock_value(Key,D) ->
    case maps:get(Key,D,undefined) of
        Value when is_binary(Value); is_integer(Value) -> Value;
        _ -> null
    end.

message(#{id := Id, text := Text, sender := Sender, sent_at_ms := Time} = M) ->
    #{id => list_to_binary(erlang:ref_to_list(Id)), text => Text,
      sender => atom_to_binary(Sender), time => Time,
      kind => atom_to_binary(maps:get(kind, M, user)),
      event => atom_to_binary(maps:get(event, M, none)),
      level => case maps:find(level, M) of {ok, L} -> atom_to_binary(L); error -> null end}.

audio_snapshot() ->
    Native = ba_mac_opus_audio:status(),
    S = case maps:get(state,Native) of stopped -> ba_mac_audio:status(); _ -> Native end,
    F = maps:get(format, S, #{}), Meter = maps:get(meter, S, #{}),
    #{available => maps:get(available, S), state => atom_to_binary(maps:get(state, S)),
      handler => maps:get(handler,S,<<"legacy_webrtc">>),
      presentation_delay_ms => ba_legacy_cluster_trust:audio_sync_delay(),
      frames => maps:get(frames, S, 0), blocks => maps:get(blocks, S, 0),
      dropped_callbacks => maps:get(dropped_callbacks, S, 0),
      skipped_frames => maps:get(skipped_frames, S, 0), send_errors => maps:get(send_errors, S, 0),
      sample_rate => maps:get(rate, F, null), channels => maps:get(channels, F, null),
      peak_db => maps:get(<<"peak_db">>, Meter, -96.0),
      rms_db => maps:get(<<"rms_db">>, Meter, -96.0),
      meter_available => map_size(Meter) > 0 andalso
          erlang:monotonic_time(millisecond) - maps:get(meter_updated,S,erlang:monotonic_time(millisecond)) < 1000,
      error => maps:get(error, S, null)}.

error_text(already_clustered_or_not_created) ->
    <<"One native cluster is remembered. Forget it before creating or joining another.">>;
error_text({authentication_timeout,opening,Details}) ->
    iolist_to_binary([error_text({authentication_timeout,opening}),"\n",
        io_lib:format("ICE: ~p; DTLS: ~p; local candidates: ~p; remote candidates: ~p; checks sent/received/replied: ~p/~p/~p",
            [maps:get(ice_state,Details,unknown),maps:get(dtls_state,Details,unknown),
             maps:get(local_candidates,Details,[]),maps:get(remote_candidates,Details,[]),
             maps:get(checks_sent,Details,0),maps:get(checks_received,Details,0),
             maps:get(responses_received,Details,0)])]);
error_text({authentication_timeout,opening}) ->
    <<"Secure peer connection did not open before the admission timeout (authentication_timeout/opening).">>;
error_text({authentication_timeout,challenge}) ->
    <<"Secure peer connection opened, but authentication timed out (authentication_timeout/challenge).">>;
error_text({authentication_timeout,pending}) ->
    <<"Admission authority did not reply before the timeout (authentication_timeout/pending).">>;
error_text(Reason) when is_binary(Reason) -> Reason;
error_text(Reason) -> iolist_to_binary(io_lib:format("Native operation: ~p", [Reason])).

event_error({rejected, Reason},_) -> error_text(Reason);
event_error({native_connected, Node, false},_) ->
    case connected_node(Node) of
        true -> null;
        false -> <<"Native connection failed. Known members reconnect automatically while online.">>
    end;
event_error({channel_stopped, _, {shutdown,peer_unavailable}},undefined) ->
    <<"Inviting peer or mailbox is unavailable at the Reception. Keep the inviting app open and retry.">>;
event_error({channel_stopped, _, Reason},undefined) ->
    iolist_to_binary(["Join did not complete (",channel_reason(Reason),
        "). Check the desk and invited peer, then submit the invitation again."]);
event_error({channel_stopped, Node, _},_) ->
    case connected_node(Node) of
        true -> null;
        false -> <<"Native channel stopped. Membership is retained; waiting to reconnect.">>
    end;
event_error(_,_) -> null.

channel_reason({shutdown,Reason}) -> channel_reason(Reason);
channel_reason(Reason) when is_atom(Reason) -> atom_to_binary(Reason);
channel_reason(_) -> <<"transport process failed">>.

connected_node(Node) ->
    lists:any(fun(N) -> N =:= Node orelse atom_to_binary(N) =:= Node end, nodes()).
