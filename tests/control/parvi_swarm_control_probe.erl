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
            try command(json:decode(unicode:characters_to_binary(Line)),Id,Cap) of
                Result -> emit(Result)
            catch Class:Reason:Stack ->
                Tag = case Reason of T when is_tuple(T) -> element(1,T);A when is_atom(A) -> A;_ -> unknown end,
                emit(#{error => probe_command_failed,class => Class,reason => Tag,
                    functions => [<<(atom_to_binary(M))/binary,":",(atom_to_binary(F))/binary>> || {M,F,_,_} <- Stack]}) end,
            loop(Id,Cap)
    end.
command(#{<<"op">> := <<"create">>,<<"desks">> := URLs},_,_) ->
    start(#{mode => create,desks => URLs});
command(#{<<"op">> := <<"join">>,<<"invitation">> := Link,<<"desk">> := Desk},_,_) ->
    start(#{mode => join,invitation => Link,desk => Desk});
command(#{<<"op">> := <<"resume">>,<<"desk">> := Desk},_,_) -> start(#{mode => resume,desk => Desk});
command(#{<<"op">> := <<"invite">>},_,_) -> result(parvi_swarm_membership:invite(3600));
command(#{<<"op">> := <<"grant">>,<<"peer">> := Peer,<<"permissions">> := Ps},_,_) ->
    result(parvi_swarm_membership:grant(Peer,Ps));
command(#{<<"op">> := <<"revoke">>,<<"peer">> := Peer},_,_) -> result(parvi_swarm_membership:revoke(Peer));
command(#{<<"op">> := <<"snapshot">>},_,_) ->
    (parvi_swarm_control:snapshot())#{node => atom_to_binary(node()),
        nodes => [atom_to_binary(N) || N <- nodes()],
        legacy_started => lists:any(fun(N) -> whereis(N) =/= undefined end,
            [parvi_cluster_desk,parvi_cluster_trust,parvi_chat,parvi_clock,parvi_audio_sup]),
        workers => proplists:get_value(active,supervisor:count_children(parvi_device_worker_sup)),
        worker_outcomes => [maps:get(state,W) || W <- maps:get(history,parvi_device_handler:status())],
        children => lists:sort([atom_to_binary(N) || {N,_,_,_} <- supervisor:which_children(parvi_sup)])};
command(#{<<"op">> := <<"connect">>,<<"peer">> := Peer},_,_) ->
    result(parvi_swarm_control:connect(Peer));
command(#{<<"op">> := <<"read">>,<<"peer">> := Peer},_,_) ->
    result(parvi_swarm_control:read_status(Peer));
command(#{<<"op">> := <<"capabilities">>,<<"peer">> := Peer},_,_) ->
    result(parvi_swarm_control:read_capabilities(Peer));
command(#{<<"op">> := <<"enable_test">>},_,_) ->
    result(parvi_device_handler:enable_test(true));
command(#{<<"op">> := <<"allow_jobs">>,<<"director">> := Director,<<"contract">> := Contract},_,_) ->
    result(parvi_device_handler:set_test_contract(Director,Contract,1));
command(#{<<"op">> := <<"offer_job">>,<<"peer">> := Peer,<<"contract">> := Contract,
          <<"duration_ms">> := Duration,<<"lease_ms">> := Lease},_,_) ->
    result(parvi_swarm_control:offer_job(Peer,#{<<"contract">> => Contract,<<"contract_revision">> => 1,
        <<"capability">> => <<"test">>,<<"duration_ms">> => Duration,<<"lease_ms">> => Lease}));
command(#{<<"op">> := <<"retry_job">>,<<"id">> := Id},_,_) -> result(parvi_swarm_control:retry_job(Id));
command(#{<<"op">> := <<"cancel_job">>,<<"id">> := Id},_,_) -> result(parvi_swarm_control:cancel_job(Id));
command(#{<<"op">> := <<"job_status">>,<<"id">> := Id},_,_) -> result(parvi_swarm_control:job_status(Id));
command(#{<<"op">> := <<"crash_worker">>},_,_) ->
    [{_,Pid,_,_}] = supervisor:which_children(parvi_device_worker_sup),exit(Pid,kill),#{ok => true};
command(#{<<"op">> := <<"attack">>,<<"peer">> := Peer},Id,_) ->
    %% Local harness access only: sign forbidden/replayed packets as the real sender.
    #{protocol := P,config := #{policy := #{swarm := Swarm,authority := Authority,director := Director,epoch := Epoch,revision := Revision},routes := _Routes}} =
        sys:get_state(parvi_swarm_control),
    #{id := Session,sent := Seq} = maps:get(Peer,maps:get(sessions,P)),
    Body = #{<<"v">> => 1,<<"from">> => Id,<<"to">> => Peer,<<"swarm">> => Swarm,
        <<"authority">> => Authority,<<"director">> => Director,<<"epoch">> => Epoch,<<"revision">> => Revision,
        <<"session">> => Session,<<"seq">> => Seq+1,
        <<"request">> => binary:copy(<<"0">>,32),<<"op">> => <<"worker.start">>,<<"payload">> => #{}},
    Private = maps:get(private,P),
    Forbidden = parvi_swarm_control_protocol:seal(Body,Private),
    {_FakePub,FakePriv} = crypto:generate_key(eddsa,ed25519),
    Forged = parvi_swarm_control_protocol:seal(Body#{<<"op">> := <<"status.read">>},FakePriv),
    Replay = parvi_swarm_control_protocol:seal(Body#{<<"seq">> := 0,<<"op">> := <<"status.read">>},Private),
    [ok = parvi_swarm_desks:send(Peer,<<"swarm_control">>,Wire) || Wire <- [Forbidden,Forged,Replay]],
    #{ok => true};
command(Other,_,_) -> parvi_audio_stream_probe:command(Other).
start(Config) ->
    application:load(parvi),application:set_env(parvi,swarm_membership,Config),
    {ok,_} = parvi:start(swarm_control),#{ok => true}.
result(ok) -> #{ok => true};
result({ok,V}) -> #{ok => true,value => V};
result({error,R}) -> #{error => R}.
emit(Value) -> io:put_chars([json:encode(Value),$\n]).
