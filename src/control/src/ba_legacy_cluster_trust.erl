%% Historical trusted-app/Distributed Erlang path; not the secure Swarm API.
%% Native trust boundary. Durable membership is separate from live grants.
-module(ba_legacy_cluster_trust).
-behaviour(gen_server).
-export([start_link/1, identity/0, policy/0, snapshot/0, create/0, invite/1, remove_both/1,
         attach/2, authorize/2, activate/2, install/1, retire/0, take_over/1, audio_sync_delay/0, set_audio_sync_delay/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

%% Persisted cluster setting; readable without a synchronous authority RPC.
audio_sync_delay() ->
    case snapshot() of
        P when is_map(P) -> maps:get(<<"audio_sync_delay_ms">>,P,1000);
        _ -> 1000
    end.
set_audio_sync_delay(Delay) when is_integer(Delay),Delay >= 5,Delay =< 30000 ->
    #{id := Id} = identity(),
    case policy() of
        P when is_map(P) ->
            try authority({audio_sync_delay,Id,Delay},P)
            catch exit:_ -> {error,authority_unavailable} end;
        _ -> {error,not_a_member}
    end;
set_audio_sync_delay(_) -> {error,<<"Offset must be 5-30000 ms.">>}.

start_link(Owner) -> gen_server:start_link({local, ?MODULE}, ?MODULE, Owner, []).
identity() -> gen_server:call(?MODULE, identity).
policy() -> gen_server:call(?MODULE, policy).
%% Clock discovery must not wait behind admission/network work in this mailbox.
snapshot() ->
    try ets:lookup(?MODULE, policy) of
        [{policy, Policy}] -> Policy;
        [] -> undefined
    catch error:badarg -> undefined end.
create() -> gen_server:call(?MODULE, create).
attach(Ctrl, Role) -> gen_server:call(?MODULE, {attach, Ctrl, Role}).
authorize(Ctrl, Node) -> gen_server:call(?MODULE, {authorize, Ctrl, Node}).
activate(Ctrl, Node) -> gen_server:call(?MODULE, {activate, Ctrl, Node}).
install(Policy) -> gen_server:call(?MODULE, {install, Policy}).
retire() -> gen_server:call(?MODULE, retire).
take_over(State) -> gen_server:call(?MODULE, {take_over, State}).
invite(TTL) ->
    #{id := Id} = identity(), authority({invite, Id, TTL}, policy()).
remove_both(Target) ->
    #{id := Id} = identity(),
    Result = try authority({remove_both, Id, Target}, policy())
             catch _:_ -> {ok, pending} end,
    case Result of {ok, _} -> retire(); _ -> ok end,
    Result.

init(Owner) ->
    process_flag(trap_exit, true),
    ets:new(?MODULE, [named_table, protected, {read_concurrency, true}]),
    {Pub, Private} = ba_device_store:identity(),
    Id = binary:encode_hex(Pub),
    Public = restore_policy(Id),
    ets:insert(?MODULE, {policy, Public}),
    ba_events:notify(policy),
    {ok, #{owner => Owner, id => Id, private => Private,
        policy => Public, sessions => #{}, grants => #{}, known => #{node() => true}, credentials => 0}}.
handle_call(identity, _, S) ->
    {reply, #{id => maps:get(id, S), node => atom_to_binary(node())}, S};
handle_call(policy, _, S) -> {reply, maps:get(policy, S), S};
handle_call(create, _, #{policy := undefined, id := Id} = S) ->
    Public = #{<<"cluster">> => ba_legacy_cluster_auth:fresh(16), <<"authority">> => atom_to_binary(node()),
        <<"revision">> => 1, <<"epoch">> => 1, <<"audio_sync_delay_ms">> => 1000, <<"members">> => #{Id => #{<<"node">> => atom_to_binary(node()),
        <<"membership">> => ba_legacy_cluster_auth:fresh(16), <<"via">> => null}}},
    {ok, _} = ba_legacy_cluster_authority:start_link(Public#{invitations => #{}}),
    {reply, {ok, Public}, checkpoint(S#{policy := Public})};
handle_call(create, _, S) -> {reply, {error, already_clustered}, S};
handle_call({attach, Ctrl, Role0}, _, #{sessions := Sessions} = S) when map_size(Sessions) < 32 ->
    try
        {Role, Next} = role(Role0, S),
        link(Ctrl),
        gen_server:cast(Ctrl, {trust_owner, self()}),
        Ref = make_ref(), erlang:send_after(10000, self(), {auth_timeout, Ctrl, Ref}),
        Session = #{role => Role, stage => opening, timer => Ref},
        {reply, ok, Next#{sessions := (maps:get(sessions, Next))#{Ctrl => Session}}}
    catch _:_ -> {reply, {error, trust_domain_or_invitation_invalid}, S} end;
handle_call({authorize, Ctrl, Node}, _, S) -> {reply, allowed(Ctrl, Node, S), S};
handle_call({activate, Ctrl, Node}, _, #{grants := Grants} = S) ->
    case allowed(Ctrl, Node, S) of
        {ok, Node} ->
            G = maps:get(Ctrl, Grants),
            {reply, {ok, Node}, S#{grants := Grants#{Ctrl := G#{native := true}}}};
        _ -> {reply, {error, unauthorized}, S}
    end;
handle_call({install, Public}, _, S) ->
    try {reply, ok, apply_policy(Public, S)}
    catch _:_ -> {reply, {error, invalid_policy}, S} end;
handle_call({take_over, State}, _, S) ->
    %% Called over the already trusted native cluster by its current authority.
    true = maps:is_key(maps:get(id, S), maps:get(<<"members">>, State)),
    {ok, _} = ba_legacy_cluster_authority:start_link(State),
    {reply, ok, S};
handle_call(retire, _, S) ->
    case whereis(ba_legacy_cluster_authority) of undefined -> ok; P -> gen_server:cast(P, stop) end,
    {reply, ok, clear(S)};
handle_call(_, _, S) -> {reply, {error, unsupported}, S}.
handle_cast(_, S) -> {noreply, S}.

handle_info({secure_ready, Ctrl, Binding}, #{sessions := Sessions} = S) ->
    case maps:find(Ctrl, Sessions) of
        {ok, #{role := server} = Session} ->
            Public = maps:get(policy, S), true = is_map(Public),
            Nonce = ba_legacy_cluster_auth:fresh(32),
            Challenge = #{<<"type">> => <<"challenge">>, <<"server">> => maps:get(id, S),
                <<"node">> => atom_to_binary(node()), <<"cluster">> => maps:get(<<"cluster">>, Public),
                <<"binding">> => Binding, <<"server_nonce">> => Nonce},
            send_auth(Ctrl, Challenge, S),
            {noreply, session(Ctrl, Session#{stage := challenge, binding => Binding, nonce => Nonce}, S)};
        {ok, Session} -> {noreply, session(Ctrl, Session#{stage := challenge, binding => Binding}, S)};
        error -> {noreply, S}
    end;
handle_info({secure_packet, Ctrl, Envelope}, S) ->
    try {noreply, packet(Ctrl, Envelope, S)}
    catch _:_ -> {noreply, reject(Ctrl, invalid_proof, S)} end;
handle_info({claim_result, Ctrl, Client, Proof, Result}, S) ->
    try
        #{stage := pending, binding := Binding, nonce := Nonce} = maps:get(Ctrl, maps:get(sessions, S)),
        {ok, Public} = Result,
        true = maps:is_key(maps:get(id, S), maps:get(<<"members">>, Public)),
        Cookie = ba_legacy_cluster_auth:fresh(32),
        Next = grant(Ctrl, Client, Public, Cookie, S),
        Grant = #{<<"type">> => <<"grant">>, <<"server">> => maps:get(id, S), <<"client">> => Client,
            <<"binding">> => Binding, <<"server_nonce">> => Nonce,
            <<"client_nonce">> => maps:get(<<"client_nonce">>, Proof),
            <<"cookie">> => Cookie, <<"policy">> => Public},
        send_auth(Ctrl, Grant, Next), {noreply, Next}
    catch _:_ -> {noreply, reject(Ctrl, admission_rejected, S)} end;
handle_info({auth_timeout, Ctrl, Ref}, #{sessions := Sessions} = S) ->
    case maps:find(Ctrl, Sessions) of
        {ok, #{timer := Ref, stage := authorized}} -> {noreply, S};
        {ok, #{timer := Ref, stage := opening}} ->
            Details = try gen_server:call(Ctrl,connection_diagnostics,1000)
                      catch exit:_ -> #{} end,
            {noreply, reject(Ctrl, {authentication_timeout,opening,Details}, S)};
        {ok, #{timer := Ref, stage := Stage}} ->
            {noreply, reject(Ctrl, {authentication_timeout,Stage}, S)};
        _ -> {noreply, S}
    end;
handle_info({'EXIT', Ctrl, _}, S) -> {noreply, forget(Ctrl, S)};
handle_info(_, S) -> {noreply, S}.

role(server, #{policy := P} = S) when is_map(P) -> {server, S};
role({join, Link}, S) ->
    {ok, Invite} = ba_legacy_cluster_auth:parse_invitation(Link),
    case maps:get(policy, S) of
        undefined -> {{join, Invite}, S};
        #{<<"cluster">> := Cluster} when Cluster =:= map_get(<<"cluster">>, Invite) -> {{join, Invite}, S};
        #{<<"members">> := Members} when map_size(Members) =:= 1 ->
            case whereis(ba_legacy_cluster_authority) of undefined -> ok; P -> gen_server:cast(P, stop) end,
            {{join, Invite}, clear(S)}
    end;
role({member, Peer}, #{policy := #{<<"members">> := Members}} = S) ->
    true = maps:is_key(Peer, Members), {{member, Peer}, S}.

packet(Ctrl, Envelope, S) ->
    Session = maps:get(Ctrl, maps:get(sessions, S)),
    #{stage := challenge, binding := Binding} = Session,
    {Body, _, _} = ba_legacy_cluster_auth:read(Envelope),
    Binding = maps:get(<<"binding">>, Body),
    case {maps:get(role, Session), maps:get(<<"type">>, Body)} of
        {server, <<"proof">>} ->
            Client = maps:get(<<"client">>, Body),
            Body = ba_legacy_cluster_auth:verify(Envelope, Client),
            true = maps:get(<<"server_nonce">>, Body) =:= maps:get(nonce, Session),
            true = maps:get(<<"cluster">>, Body) =:= maps:get(<<"cluster">>, maps:get(policy, S)),
            Policy = maps:get(policy, S), Issuer = maps:get(id, S), Owner = self(),
            %% Reconnect known members from local durable permission, even when
            %% the admission authority is offline. Fresh proof is still required.
            Next = case maps:get(<<"mode">>, Body) of
                <<"member">> ->
                    MemberPolicy = maps:get(<<"policy">>, Body),
                    Updated = reconcile_member(Client, maps:get(<<"node">>, Body), MemberPolicy, S),
                    self() ! {claim_result, Ctrl, Client, Body, {ok, maps:get(policy, Updated)}},
                    Updated;
                <<"join">> ->
                    spawn(fun() ->
                        Result = try
                            Name = maps:get(<<"node">>, Body),
                            authority({claim, Issuer, maps:get(<<"invite">>, Body),
                                maps:get(<<"secret">>, Body), Client, Name}, Policy)
                        catch _:_ -> {error, authority_unavailable} end,
                        Owner ! {claim_result, Ctrl, Client, Body, Result}
                    end), S
            end,
            session(Ctrl, Session#{stage := pending}, Next);
        {Role, <<"challenge">>} ->
            {Server, Cluster} = expected(Role, S),
            Body = ba_legacy_cluster_auth:verify(Envelope, Server),
            Cluster = maps:get(<<"cluster">>, Body), Server = maps:get(<<"server">>, Body),
            true = maps:get(<<"node">>, Body) =:= peer_name(Role, Server, S),
            Nonce = ba_legacy_cluster_auth:fresh(32),
            Proof0 = #{<<"type">> => <<"proof">>, <<"client">> => maps:get(id, S),
                <<"node">> => atom_to_binary(node()), <<"cluster">> => Cluster, <<"binding">> => Binding,
                <<"server_nonce">> => maps:get(<<"server_nonce">>, Body), <<"client_nonce">> => Nonce},
            Proof = case Role of
                {join, Invite} -> Proof0#{<<"mode">> => <<"join">>, <<"invite">> => maps:get(<<"invite">>, Invite),
                    <<"secret">> => maps:get(<<"secret">>, Invite)};
                {member, _} -> Proof0#{<<"mode">> => <<"member">>, <<"policy">> => maps:get(policy, S)}
            end,
            send_auth(Ctrl, Proof, S),
            session(Ctrl, Session#{server_nonce => maps:get(<<"server_nonce">>, Body),
                client_nonce => Nonce}, S);
        {Role, <<"grant">>} ->
            {Server, Cluster} = expected(Role, S),
            Body = ba_legacy_cluster_auth:verify(Envelope, Server),
            Server = maps:get(<<"server">>, Body),
            true = maps:get(id, S) =:= maps:get(<<"client">>, Body),
            true = maps:get(<<"server_nonce">>, Body) =:= maps:get(server_nonce, Session),
            true = maps:get(<<"client_nonce">>, Body) =:= maps:get(client_nonce, Session),
            Public = maps:get(<<"policy">>, Body), Cluster = maps:get(<<"cluster">>, Public),
            case Role of
                {member, _} ->
                    true = maps:get(<<"epoch">>, Public) =:= maps:get(<<"epoch">>, maps:get(policy, S));
                _ -> ok
            end,
            #{<<"node">> := ServerName} = maps:get(Server, maps:get(<<"members">>, Public)),
            ServerName = peer_name(Role, Server, S),
            grant(Ctrl, Server, Public, maps:get(<<"cookie">>, Body), S)
    end.

expected({join, Invite}, _) -> {maps:get(<<"issuer">>, Invite), maps:get(<<"cluster">>, Invite)};
expected({member, Peer}, #{policy := P}) -> {Peer, maps:get(<<"cluster">>, P)}.
peer_name({join, Invite}, _, _) -> maps:get(<<"node">>, Invite);
peer_name({member, _}, Peer, #{policy := #{<<"members">> := M}}) -> maps:get(<<"node">>, maps:get(Peer, M)).

grant(Ctrl, Peer, Public, Cookie, S) ->
    true = is_binary(Cookie) andalso byte_size(Cookie) =:= 64,
    true = maps:is_key(maps:get(id, S), maps:get(<<"members">>, Public)),
    #{<<"node">> := OwnName} = maps:get(maps:get(id, S), maps:get(<<"members">>, Public)),
    true = OwnName =:= atom_to_binary(node()),
    Next = case maps:get(policy, S) of undefined -> checkpoint(S#{policy := Public}); _ -> apply_policy(Public, S) end,
    Member = maps:get(Peer, maps:get(<<"members">>, Public)), Name = maps:get(<<"node">>, Member),
    true = ba_legacy_cluster_auth:valid_name(Name),
    Known = maps:get(known, Next), true = map_size(Known) < 256 orelse maps:is_key(Name, Known),
    Credentials = maps:get(credentials, Next), true = Credentials < 4096,
    Node = binary_to_atom(Name), true = erlang:set_cookie(Node, binary_to_atom(Cookie)),
    ok = net_kernel:allow([Node]), ba_webrtc_dist:route(Node, Ctrl),
    G = #{peer => Peer, node => Node, member => maps:get(<<"membership">>, Member),
          epoch => maps:get(<<"epoch">>, Public), native => false},
    #{owner := Owner, sessions := Sessions, grants := Grants} = Next,
    Owner ! {trust, Ctrl, authorized, Node},
    Session = maps:get(Ctrl, Sessions),
    Next#{known := Known#{Name => true}, credentials := Credentials + 1, grants := Grants#{Ctrl => G},
        sessions := Sessions#{Ctrl := (maps:without([role], Session))#{stage := authorized}}}.

allowed(Ctrl, Expected, #{policy := #{<<"epoch">> := Epoch, <<"members">> := Members}, grants := Gs, id := Id}) ->
    case maps:find(Ctrl, Gs) of
        {ok, #{peer := Peer, node := Node, member := Membership, epoch := Epoch}} ->
            case maps:is_key(Id, Members) andalso is_process_alive(Ctrl) andalso
                    (Expected =:= any orelse Expected =:= Node) andalso
                    maps:get(<<"membership">>, maps:get(Peer, Members, #{}), undefined) =:= Membership of
                true -> {ok, Node}; false -> {error, unauthorized}
            end;
        _ -> {error, unauthorized}
    end;
allowed(_, _, _) -> {error, unauthorized}.

apply_policy(Public, #{policy := Old, id := Id} = S) ->
    true = is_map(Old),
    true = maps:get(<<"cluster">>, Public) =:= maps:get(<<"cluster">>, Old),
    true = maps:get(<<"revision">>, Public) >= maps:get(<<"revision">>, Old),
    case maps:get(<<"revision">>, Public) =:= maps:get(<<"revision">>, Old) of
        true -> Public = Old; false -> ok
    end,
    Members = maps:get(<<"members">>, Public),
    case maps:is_key(Id, Members) of
        false -> clear(S);
        true ->
            Next = checkpoint(S#{policy := Public}),
            maps:fold(fun(Ctrl, Grant, Acc) ->
                Peer = maps:get(peer, Grant),
                SameMember = maps:get(<<"membership">>, maps:get(Peer, Members, #{}), undefined)
                    =:= maps:get(member, Grant),
                SameEpoch = maps:get(epoch, Grant) =:= maps:get(<<"epoch">>, Public),
                case SameMember andalso (SameEpoch orelse maps:get(native, Grant)) of
                    true -> Acc#{grants := (maps:get(grants, Acc))#{Ctrl :=
                        Grant#{epoch := maps:get(<<"epoch">>, Public)}}};
                    false -> exit(Ctrl, {shutdown, revoked}), forget(Ctrl, Acc)
                end
            end, Next, maps:get(grants, S))
    end.

clear(S) ->
    [exit(Ctrl, {shutdown, cluster_removed}) || Ctrl <- maps:keys(maps:get(sessions, S))],
    lists:foldl(fun forget/2, checkpoint(S#{policy := undefined}), maps:keys(maps:get(sessions, S))).
forget(Ctrl, #{sessions := Sessions, grants := Grants} = S) ->
    case maps:find(Ctrl, Grants) of
        {ok, #{node := Node}} ->
            case ba_webrtc_dist:unroute(Node, Ctrl) of
                removed -> erlang:set_cookie(Node, erlang:get_cookie());
                unchanged -> ok
            end;
        error -> ok
    end,
    S#{sessions := maps:remove(Ctrl, Sessions), grants := maps:remove(Ctrl, Grants)}.
reject(Ctrl, Reason, #{owner := Owner} = S) ->
    Owner ! {trust, Ctrl, rejected, Reason}, exit(Ctrl, {shutdown, unauthorized}), forget(Ctrl, S).
session(Ctrl, Session, S) -> S#{sessions := (maps:get(sessions, S))#{Ctrl := Session}}.
send_auth(Ctrl, Body, S) ->
    gen_server:cast(Ctrl, {control, ba_legacy_cluster_auth:sign(Body, maps:get(private, S))}).
authority(Command, #{<<"authority">> := Node}) ->
    gen_server:call({ba_legacy_cluster_authority, binary_to_existing_atom(Node)}, Command, 10000).

checkpoint(#{policy := Public, owner := Owner} = S) ->
    ok = ba_device_store:save(policy, Public),
    case Public of
        undefined -> case whereis(ba_audio_receiver) of
            undefined -> ok = ba_device_store:save(audio_subscription,undefined);
            Receiver -> ok = gen_server:call(Receiver,forget_subscription)
        end;
        _ -> ok
    end,
    ets:insert(?MODULE, {policy, Public}),
    ba_events:notify(policy),
    case whereis(ba_swarm_clock) of undefined -> ok; Clock -> Clock ! membership_changed end,
    Owner ! {trust, policy_changed}, S.

restore_policy(Id) ->
    case ba_device_store:load(policy, undefined) of
        undefined -> undefined;
        #{<<"authority">> := Authority, <<"members">> := Members} = Public ->
            #{<<"node">> := Name} = maps:get(Id, Members),
            Name = atom_to_binary(node()),
            case Authority =:= Name of
                false -> Public;
                true ->
                    {module, ba_legacy_cluster_authority} = code:ensure_loaded(ba_legacy_cluster_authority),
                    Saved = ba_device_store:load(authority, undefined),
                    State = case Saved of
                        #{<<"cluster">> := Cluster} when Cluster =:= map_get(<<"cluster">>, Public) ->
                            true = maps:get(<<"revision">>, Saved) >= maps:get(<<"revision">>, Public), Saved;
                        _ -> Public#{invitations => #{}}
                    end,
                    {ok, _} = ba_legacy_cluster_authority:start_link(State),
                    Restored = ba_legacy_cluster_authority:public(State),
                    ok = ba_device_store:save(policy, Restored), Restored
            end
    end.

reconcile_member(Client, Name, Remote, #{id := Id, policy := Local} = S) ->
    true = maps:get(<<"cluster">>, Remote) =:= maps:get(<<"cluster">>, Local),
    true = maps:get(<<"epoch">>, Remote) =:= maps:get(<<"epoch">>, Local),
    LocalMembers = maps:get(<<"members">>, Local), RemoteMembers = maps:get(<<"members">>, Remote),
    %% Both sides must already remember these exact memberships. A reconnect
    %% is never a route for a new identity or a changed membership token.
    [true = maps:get(P, LocalMembers) =:= maps:get(P, RemoteMembers) || P <- [Id, Client]],
    #{<<"node">> := Name} = maps:get(Client, LocalMembers),
    case maps:get(<<"revision">>, Remote) > maps:get(<<"revision">>, Local) of
        false -> S;
        true ->
            true = maps:get(<<"authority">>, Remote) =:= maps:get(<<"authority">>, Local),
            true = maps:with(maps:keys(LocalMembers), RemoteMembers) =:= LocalMembers,
            apply_policy(Remote, S)
    end.
