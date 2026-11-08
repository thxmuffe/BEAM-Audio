%% Disposable integration harness, never packaged as a runtime command endpoint.
-module(parvi_swarm_control_probe).
-export([main/0]).

main() ->
    logger:set_primary_config(level,critical),
    {ok,_} = application:ensure_all_started(crypto),
    {Pub,_} = parvi_cluster_store:identity(),
    Id = binary:encode_hex(Pub), Cap = binary:encode_hex(crypto:strong_rand_bytes(16)),
    emit(#{id => Id,mailbox => Cap}), loop(Id,Cap).
loop(Id,Cap) ->
    case io:get_line("") of
        eof -> halt(0);
        Line ->
            try command(json:decode(list_to_binary(Line)),Id,Cap) of
                Result -> emit(Result)
            catch _:_ -> emit(#{error => probe_command_failed}) end,
            loop(Id,Cap)
    end.
command(#{<<"op">> := <<"configure">>,<<"peer">> := Peer,<<"mailbox">> := PeerCap,
          <<"swarm">> := Swarm,<<"url">> := URL},Id,Cap) ->
    Policy = #{swarm => Swarm,authority => min(Id,Peer),epoch => 1,revision => 1,
               peers => #{Peer => [capabilities_read,status_read]}},
    application:load(parvi),
    application:set_env(parvi,reception_desk_url,URL),
    application:set_env(parvi,swarm_control,#{policy => Policy,mailbox => Cap,routes => #{Peer => PeerCap}}),
    {ok,_} = parvi:start(swarm_control), #{ok => true};
command(#{<<"op">> := <<"snapshot">>},_,_) ->
    (parvi_swarm_control:snapshot())#{node => atom_to_binary(node()),
        nodes => [atom_to_binary(N) || N <- nodes()],
        legacy_started => lists:any(fun(N) -> whereis(N) =/= undefined end,
            [parvi_cluster_desk,parvi_cluster_trust,parvi_chat,parvi_clock,parvi_audio_sup]),
        workers => proplists:get_value(active,supervisor:count_children(parvi_device_worker_sup)),
        children => lists:sort([atom_to_binary(N) || {N,_,_,_} <- supervisor:which_children(parvi_sup)])};
command(#{<<"op">> := <<"connect">>,<<"peer">> := Peer},_,_) ->
    result(parvi_swarm_control:connect(Peer));
command(#{<<"op">> := <<"read">>,<<"peer">> := Peer},_,_) ->
    result(parvi_swarm_control:read_status(Peer));
command(#{<<"op">> := <<"capabilities">>,<<"peer">> := Peer},_,_) ->
    result(parvi_swarm_control:read_capabilities(Peer));
command(#{<<"op">> := <<"enable_test">>},_,_) ->
    result(parvi_device_handler:enable_test(true));
command(#{<<"op">> := <<"attack">>,<<"peer">> := Peer},Id,_) ->
    %% Local harness access only: sign forbidden/replayed packets as the real sender.
    #{protocol := P,config := #{policy := #{swarm := Swarm,authority := Authority},routes := Routes}} =
        sys:get_state(parvi_swarm_control),
    #{id := Session,sent := Seq} = maps:get(Peer,maps:get(sessions,P)),
    Body = #{<<"v">> => 1,<<"from">> => Id,<<"to">> => Peer,<<"swarm">> => Swarm,
        <<"authority">> => Authority,<<"epoch">> => 1,<<"revision">> => 1,
        <<"session">> => Session,<<"seq">> => Seq+1,
        <<"request">> => binary:copy(<<"0">>,32),<<"op">> => <<"worker.start">>,<<"payload">> => #{}},
    Private = maps:get(private,P),
    Forbidden = parvi_swarm_control_protocol:seal(Body,Private),
    {_FakePub,FakePriv} = crypto:generate_key(eddsa,ed25519),
    Forged = parvi_swarm_control_protocol:seal(Body#{<<"op">> := <<"status.read">>},FakePriv),
    Replay = parvi_swarm_control_protocol:seal(Body#{<<"seq">> := 0,<<"op">> := <<"status.read">>},Private),
    [ok = parvi_relay:send(Peer,maps:get(Peer,Routes),#{<<"type">> => <<"swarm_control">>,
        <<"swarm">> => Swarm,<<"packet">> => Wire}) || Wire <- [Forbidden,Forged,Replay]],
    #{ok => true}.
result(ok) -> #{ok => true};
result({ok,V}) -> #{ok => true,value => V};
result({error,R}) -> #{error => R}.
emit(Value) -> io:put_chars([json:encode(Value),$\n]).
