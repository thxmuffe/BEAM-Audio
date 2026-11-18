%% Disposable integration harness, never packaged as a runtime command endpoint.
-module(ba_buffee_control_probe).
-export([main/0,crash_child/0]).
crash_child() -> {ok,spawn_link(fun() -> receive crash -> exit({badmatch,<<"PRIVATE_EXCEPTION">>}) end end)}.

main() ->
    logger:set_primary_config(level,case os:getenv("BA_TEST_VERBOSE") of false -> critical;_ -> warning end),
    {ok,_} = application:ensure_all_started(crypto),
    {Pub,_} = ba_device_store:identity(),
    Id = binary:encode_hex(Pub), Cap = binary:encode_hex(crypto:strong_rand_bytes(16)),
    emit(#{id => Id,mailbox => Cap}), loop(Id,Cap).
loop(Id,Cap) ->
    case io:get_line("") of
        %% Settings are written ?DELAY ms after a change; save them before halting.
        eof -> _=catch_flush(),halt(0);
        Line ->
            try command(json:decode(unicode:characters_to_binary(Line)),Id,Cap) of
                Result -> emit(Result)
            catch Class:Reason:Stack ->
                Tag = case Reason of T when is_tuple(T) -> element(1,T);A when is_atom(A) -> A;_ -> unknown end,
                emit(#{error => probe_command_failed,class => Class,reason => Tag,
                    functions => [<<(atom_to_binary(M))/binary,":",(atom_to_binary(F))/binary>> || {M,F,_,_} <- Stack]}) end,
            loop(Id,Cap)
    end.
command(#{<<"op">> := <<"start_runtime">>},_,_) -> ensure_started(),ba_app_session:snapshot();
command(#{<<"op">> := <<"chat_history">>},_,_) -> ba_buffee_chat:history();
%% The app path: the same Device API the windows use (it also records Session memory).
%% Like the CLI and the apps: the app layer, so the audio worker (which opens links) runs.
command(#{<<"op">> := <<"configure_app">>},_,_) ->
    application:load(ba_core),result(ba_app_session:configure(#{platform => mac,consent => #{speaker => false,microphone => false,broadcast => false}}));
command(#{<<"op">> := <<"debug_control">>},_,_) ->
    #{protocol := P}=sys:get_state(ba_session_scope:ref(ba_buffee_control)),
    #{peers => [binary:part(K,0,6) || K <- maps:keys(maps:get(peers,maps:get(policy,P,#{}),#{}))],
      deadline => maps:get(membership_deadline,P,none),now => erlang:monotonic_time(millisecond),
      sessions => [binary:part(K,0,6) || K <- maps:keys(maps:get(sessions,P,#{}))],
      control_pid => list_to_binary(pid_to_list(ba_session_scope:whereis(ba_buffee_control))),
      rejection => list_to_binary(io_lib:format("~p",[maps:get(last_rejection,sys:get_state(ba_session_scope:ref(ba_buffee_control)),none)])),
      diag => list_to_binary(io_lib:format("~p",[ba_diagnostics:view(sys:get_state(ba_session_scope:ref(ba_buffee_control)))])),
      config_hash => erlang:phash2(maps:get(config,sys:get_state(ba_session_scope:ref(ba_buffee_control)))),
      routes => erlang:phash2(maps:get(routes,maps:get(config,sys:get_state(ba_session_scope:ref(ba_buffee_control))))),
      revision => maps:get(revision,maps:get(policy,P,#{}),none),
      membership => case ba_buffee_membership:current() of
          {ok,#{policy := #{peers := Peers}}} -> [binary:part(K,0,6) || K <- maps:keys(Peers)];
          Other -> list_to_binary(io_lib:format("~p",[Other])) end};
command(#{<<"op">> := <<"debug_trace_start">>},_,_) ->
    Collector=spawn(fun() -> (fun Loop(Acc) -> receive {get,From} -> From ! {traced,lists:reverse(Acc)},Loop(Acc);
        {trace,_,call,{M,F,Args}} -> Loop([{M,F,length(Args),case {F,Args} of
            {handle_info,[Msg|_]} when is_tuple(Msg) -> element(1,Msg);{handle_info,[Msg|_]} when is_atom(Msg) -> Msg;
            {close_peer,[_,Reason|_]} -> Reason;{rejected,[Reason|_]} -> Reason;{reset,[Reason|_]} -> Reason;_ -> x end}|Acc]);
        _ -> Loop(Acc) end end)([]) end),
    register(ba_debug_collector,Collector),
    erlang:trace(ba_session_scope:whereis(ba_buffee_control),true,[call,{tracer,Collector}]),
    erlang:trace_pattern({ba_buffee_control,'_','_'},true,[local]),
    erlang:trace_pattern({ba_buffee_control_protocol,'_','_'},true,[local]),#{ok => true};
command(#{<<"op">> := <<"debug_trace_get">>},_,_) ->
    ba_debug_collector ! {get,self()},
    receive {traced,L} -> [list_to_binary(io_lib:format("~p:~p/~p ~p",[M,F,A,X])) || {M,F,A,X} <- L,
        not lists:member(F,[now_ms,hex,uint,exact,fresh,nonces,decode,put,format_status])] after 2000 -> [] end;
command(#{<<"op">> := <<"api">>,<<"request">> := Request},_,_) -> ensure_started(),ba_device_api:request(Request);
command(#{<<"op">> := <<"crash_test_worker">>},_,_) ->
    logger:set_primary_config(level,error),logger:set_handler_config(default,level,critical),
    {ok,Child}=supervisor:start_child(ba_device_sup,
        #{id => ba_crash_test_child,start => {?MODULE,crash_child,[]},restart => temporary}),
    Child ! crash,#{ok => true};
command(#{<<"op">> := <<"set_observer">>},_,_) ->
    application:set_env(ba_core,buffee_observer,true),#{ok => true};
command(#{<<"op">> := <<"start_app">>},_,_) ->
    application:load(ba_core),application:set_env(ba_core,restore_buffee_on_start,true),
    ensure_started(),ba_app_session:snapshot();
command(#{<<"op">> := <<"disconnect_app">>},_,_) -> result(ba_buffee:disconnect());
command(#{<<"op">> := <<"create">>,<<"desks">> := URLs},_,_) ->
    start(#{mode => create,name => <<"Test gathering">>,desks => URLs});
command(#{<<"op">> := <<"join">>,<<"invitation">> := Link,<<"desk">> := Desk},_,_) ->
    start(#{mode => join,invitation => Link,desk => Desk});
command(#{<<"op">> := <<"create_buffee">>,<<"name">> := Name,<<"desks">> := URLs},_,_) ->
    ensure_started(),result(ba_buffee:create(Name,URLs));
command(#{<<"op">> := <<"join_buffee">>,<<"invitation">> := Link},_,_) ->
    ensure_started(),result(ba_buffee:join(Link));
command(#{<<"op">> := <<"invite_buffee">>,<<"selection">> := Sel},_,_) ->
    ensure_started(),Selection = case Sel of #{<<"group">> := G} -> {group,G};L -> L end,
    result(ba_buffee:invite(Selection,3600));
command(#{<<"op">> := <<"leave_buffee">>},_,_) -> ensure_started(),result(ba_buffee:leave());
command(#{<<"op">> := <<"end_buffee">>},_,_) -> ensure_started(),result(ba_buffee:end_buffee());
command(#{<<"op">> := <<"buffee_status">>},_,_) -> ensure_started(),ba_buffee:status();
command(#{<<"op">> := <<"lifecycle">>},_,_) ->
    ensure_started(),
    #{buffee => ba_buffee:status(),transient_state => ets:whereis(ba_buffee_state)=/=undefined,
      connections => map_size(ba_desk_connections_sup:connections()),
      live => [atom_to_binary(N) || N <- [ba_buffee_runtime_sup,ba_buffee_membership,
        ba_device_sup,ba_buffee_control,ba_buffee_clock_sup,ba_buffee_clock,
        ba_audio_sup,ba_audio_receiver,ba_audio_mixer],is_pid(whereis(N))]};
command(#{<<"op">> := <<"crash_buffee">>},_,_) -> exit(whereis(ba_buffee_membership),kill),#{ok => true};
command(#{<<"op">> := <<"list_contacts">>},_,_) -> ensure_started(),ba_contacts:list();
command(#{<<"op">> := <<"put_contact">>,<<"id">> := Id,<<"name">> := Name},_,_) ->
    ensure_started(),result(ba_contacts:put(Id,Name));
command(#{<<"op">> := <<"delete_contact">>,<<"id">> := Id},_,_) ->
    ensure_started(),result(ba_contacts:delete(Id));
command(#{<<"op">> := <<"group_contacts">>,<<"name">> := Name,<<"ids">> := Ids},_,_) ->
    ensure_started(),result(ba_contacts:group(Name,Ids));
command(#{<<"op">> := <<"delete_group">>,<<"name">> := Name},_,_) ->
    ensure_started(),result(ba_contacts:delete_group(Name));
command(#{<<"op">> := <<"invite">>},_,_) -> result(ba_buffee_membership:invite(3600));
command(#{<<"op">> := <<"grant">>,<<"peer">> := Peer,<<"permissions">> := Ps},_,_) ->
    result(ba_buffee_membership:grant(Peer,Ps));
command(#{<<"op">> := <<"answer_on_air_requests">>,<<"value">> := V},_,_) ->
    result(ba_device_config:policy(on_air_requests,binary_to_existing_atom(V),#{}));
command(#{<<"op">> := <<"decline_privilege">>,<<"peer">> := Peer,<<"privilege">> := Name},_,_) ->
    result(ba_buffee_membership:decline_privilege(Peer,ba_session_privileges:parse(Name)));
command(#{<<"op">> := <<"request_privilege">>,<<"privilege">> := Name},_,_) ->
    result(ba_buffee_membership:request_privilege(ba_session_privileges:parse(Name)));
command(#{<<"op">> := <<"grant_privilege">>,<<"peer">> := Peer,<<"privilege">> := Name},_,_) ->
    result(ba_buffee_membership:grant_privilege(Peer,ba_session_privileges:parse(Name)));
command(#{<<"op">> := <<"take_privilege">>,<<"peer">> := Peer,<<"privilege">> := Name},_,_) ->
    result(ba_buffee_membership:take_privilege(Peer,ba_session_privileges:parse(Name)));
command(#{<<"op">> := <<"revoke">>,<<"peer">> := Peer},_,_) -> result(ba_buffee_membership:revoke(Peer));
command(#{<<"op">> := <<"snapshot">>},_,_) ->
    (ba_buffee_control:snapshot())#{node => atom_to_binary(node()),
        nodes => [atom_to_binary(N) || N <- nodes()],
        old_core_loaded => lists:any(fun({M,_}) ->
            M=:=list_to_atom("par"++"vi") orelse lists:prefix("par"++"vi_",atom_to_list(M))
        end,code:all_loaded()),
        legacy_started => lists:any(fun(N) -> whereis(N) =/= undefined end,
            [ba_legacy_cluster_desk,ba_legacy_cluster_trust,ba_chat,ba_audio_sup]),
        workers => proplists:get_value(active,supervisor:count_children(ba_device_worker_sup)),
        worker_outcomes => [maps:get(state,W) || W <- maps:get(history,ba_device_handler:status())],
        children => lists:sort([atom_to_binary(N) || {N,_,_,_} <- supervisor:which_children(ba_sup)])};
command(#{<<"op">> := <<"connect">>,<<"peer">> := Peer},_,_) ->
    result(ba_buffee_control:connect(Peer));
command(#{<<"op">> := <<"read">>,<<"peer">> := Peer},_,_) ->
    result(ba_buffee_control:read_status(Peer));
command(#{<<"op">> := <<"capabilities">>,<<"peer">> := Peer},_,_) ->
    result(ba_buffee_control:read_capabilities(Peer));
command(#{<<"op">> := <<"enable_test">>},_,_) ->
    %% The test job also needs this Device's DSP consent (the `friendly` preset).
    ok=ba_device_config:preset(friendly,#{}),
    result(ba_device_handler:enable_test(true));
command(#{<<"op">> := <<"allow_jobs">>,<<"manager">> := Manager,<<"contract">> := Contract},_,_) ->
    result(ba_device_handler:set_test_contract(Manager,Contract,1));
command(#{<<"op">> := <<"offer_job">>,<<"peer">> := Peer,<<"contract">> := Contract,
          <<"duration_ms">> := Duration,<<"lease_ms">> := Lease},_,_) ->
    result(ba_buffee_control:offer_job(Peer,#{<<"contract">> => Contract,<<"contract_revision">> => 1,
        <<"capability">> => <<"test">>,<<"duration_ms">> => Duration,<<"lease_ms">> => Lease}));
command(#{<<"op">> := <<"retry_job">>,<<"id">> := Id},_,_) -> result(ba_buffee_control:retry_job(Id));
command(#{<<"op">> := <<"cancel_job">>,<<"id">> := Id},_,_) -> result(ba_buffee_control:cancel_job(Id));
command(#{<<"op">> := <<"job_status">>,<<"id">> := Id},_,_) -> result(ba_buffee_control:job_status(Id));
command(#{<<"op">> := <<"crash_worker">>},_,_) ->
    [{_,Pid,_,_}] = supervisor:which_children(ba_device_worker_sup),exit(Pid,kill),#{ok => true};
command(#{<<"op">> := <<"attack">>,<<"peer">> := Peer},Id,_) ->
    %% Local harness access only: sign forbidden/replayed packets as the real sender.
    #{protocol := P,config := #{policy := #{buffee := Buffee,authority := Authority,manager := Manager,epoch := Epoch,revision := Revision},routes := _Routes}} =
        sys:get_state(ba_buffee_control),
    #{id := Session,sent := Seq} = maps:get(Peer,maps:get(sessions,P)),
    Body = #{<<"v">> => 1,<<"from">> => Id,<<"to">> => Peer,<<"buffee">> => Buffee,
        <<"authority">> => Authority,<<"manager">> => Manager,<<"epoch">> => Epoch,<<"revision">> => Revision,
        <<"session">> => Session,<<"seq">> => Seq+1,
        <<"request">> => binary:copy(<<"0">>,32),<<"op">> => <<"worker.start">>,<<"payload">> => #{}},
    Private = maps:get(private,P),
    Forbidden = ba_buffee_control_protocol:seal(Body,Private),
    {_FakePub,FakePriv} = crypto:generate_key(eddsa,ed25519),
    Forged = ba_buffee_control_protocol:seal(Body#{<<"op">> := <<"status.read">>},FakePriv),
    Replay = ba_buffee_control_protocol:seal(Body#{<<"seq">> := 0,<<"op">> := <<"status.read">>},Private),
    [ok = ba_buffee_desks:send(Peer,<<"buffee_control">>,Wire) || Wire <- [Forbidden,Forged,Replay]],
    #{ok => true};
command(#{<<"op">> := <<"clock_snapshot">>},_,_) -> ba_buffee_clock:status();
command(#{<<"op">> := <<"clock_prepare">>,<<"interval_ms">> := I,<<"samples">> := Count},_,_) ->
    application:load(ba_core),application:set_env(ba_core,clock_reference,system),
    application:set_env(ba_core,clock_sample_interval_ms,I),application:set_env(ba_core,clock_filter_samples,Count),
    #{ok => true};
command(#{<<"op">> := <<"offset_set">>,<<"offset_ms">> := Value,<<"revision">> := Rev},_,_) ->
    result(ba_buffee_clock:set_offset(Value,Rev));
command(#{<<"op">> := <<"offset_set">>,<<"offset_ms">> := Value},_,_) -> result(ba_buffee_clock:set_offset(Value));
command(#{<<"op">> := <<"clock_resync">>},_,_) -> result(ba_buffee_clock:resync());
command(#{<<"op">> := <<"clock_reference">>},_,_) -> result(ba_buffee_clock:set_reference(system));
command(#{<<"op">> := <<"clock_restart">>},_,_) ->
    restart(ba_buffee_clock),#{ok => true,initial => ba_buffee_clock:status()};
command(#{<<"op">> := <<"control_reset">>},_,_) -> restart(ba_buffee_control),#{ok => true};
command(#{<<"op">> := <<"backend_ids">>},_,_) ->
    %% Supervisor reports include child start arguments. Identity must be loaded
    %% inside each relay, never supplied in its child specification.
    {_,Private} = ba_device_store:identity(),
    [begin {ok,Spec} = supervisor:get_childspec(ba_desk_connections_sup,URL),
        nomatch = binary:match(term_to_binary(Spec),Private)
     end || URL <- maps:keys(ba_desk_connections_sup:connections())],
    #{processes => maps:from_list([{atom_to_binary(N),list_to_binary(pid_to_list(whereis(N)))} || N <-
        [ba_buffee_desks,ba_buffee_membership,ba_device_sup,ba_device_worker_sup,ba_buffee_control,ba_buffee_clock]]),
      sessions => maps:map(fun(_,V) -> maps:get(id,V) end,maps:get(sessions,maps:get(protocol,sys:get_state(ba_buffee_control)))),
      workers => lists:sort([list_to_binary(pid_to_list(P)) || {_,P,_,_} <- supervisor:which_children(ba_device_worker_sup),is_pid(P)])};
command(#{<<"op">> := <<"desk_crash">>,<<"desk">> := URL},_,_) ->
    P = maps:get(URL,ba_desk_connections_sup:connections()),exit(P,kill),#{ok => true};
command(#{<<"op">> := <<"renewal_prepare">>,<<"lease_ms">> := Lease},_,_) when Lease>=2000,Lease=<60000 ->
    application:load(ba_core),application:set_env(ba_core,control_session_lease_ms,Lease),#{ok => true};
command(#{<<"op">> := <<"block_handshakes">>},_,_) ->
    %% Test-only network fault: keep membership/time/data traffic, drop control
    %% handshakes and renewal proofs. Production code has no such bypass/switch.
    Filter = spawn(fun filter_handshakes/0),
    [sys:replace_state(P,fun(S) -> S#{owner := Filter} end) || P <- maps:values(ba_desk_connections_sup:connections())],
    #{ok => true};
command(Other,_,_) -> ba_audio_stream_probe:command(Other).
ensure_started() ->
    case whereis(ba_sup) of
        undefined ->
            application:load(ba_core),
            application:set_env(ba_core,clock_reference,system),
            {ok,_} = ba_runtime:start(buffee_control),
            ok;
        _ -> ok
    end.
start(Config) ->
    ensure_started(),
    result(ba_buffee:start(Config)).
result(ok) -> #{ok => true};
result({ok,V}) -> #{ok => true,value => V};
result({error,R}) -> #{error => R}.
emit(Value) -> io:put_chars([json:encode(Value),$\n]).

restart(Module) ->
    Old = whereis(Module),Ref = monitor(process,Old),exit(Old,kill),
    receive {'DOWN',Ref,process,Old,_} -> ok after 1000 -> error(owner_not_down) end,
    await_owner(Module,Old,100).
await_owner(_,_,0) -> error(owner_not_restarted);
await_owner(Module,Old,N) ->
    case whereis(Module) of
        New when is_pid(New),New=/=Old -> _ = gen_server:call(New,test_ready),ok;
        _ -> receive after 10 -> await_owner(Module,Old,N-1) end
    end.

filter_handshakes() ->
    receive
        Message ->
            Drop = try
                {relay,_,{delivery,_,_,#{<<"type">> := <<"buffee_control">>,<<"packet">> := P}}} = Message,
                #{<<"body">> := B} = json:decode(P),#{<<"op">> := Op} = json:decode(base64:decode(B)),
                lists:member(Op,[<<"hello">>,<<"challenge">>,<<"proof">>,<<"ready">>,
                    <<"lease.request">>,<<"lease.challenge">>,<<"lease.proof">>,<<"lease.ready">>])
            catch _:_ -> false end,
            case Drop of true -> ok;false -> ba_buffee_desks ! Message end,
            filter_handshakes()
    end.
catch_flush() -> case whereis(ba_settings) of undefined -> ok;_ -> ba_settings:flush() end.
