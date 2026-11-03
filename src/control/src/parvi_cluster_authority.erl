%% A movable, cluster-local OTP admission actor. No public service or shared cookie.
%% Existing trusted nodes can all issue invitations; this actor serializes policy.
-module(parvi_cluster_authority).
-behaviour(gen_server).
-export([start_link/1, public/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

start_link(State) -> gen_server:start_link({local, ?MODULE}, ?MODULE, State, []).
public(S) -> maps:with([<<"cluster">>, <<"authority">>, <<"revision">>, <<"epoch">>, <<"members">>], S).
init(State) ->
    ok = parvi_cluster_store:save(authority, maps:remove(finalize, State)),
    case maps:get(finalize, State, false) of true -> self() ! publish; false -> ok end,
    {ok, maps:remove(finalize, State)}.
handle_call({invite, Issuer, TTL}, {Caller, _}, S) when is_integer(TTL), TTL > 0, TTL =< 604800 ->
    case caller(Issuer, Caller, S) of
        false -> {reply, {error, not_a_member}, S};
        true ->
            Id = parvi_cluster_auth:fresh(16), Secret = parvi_cluster_auth:fresh(32),
            Expiry = erlang:system_time(second) + TTL,
            Entry = #{issuer => Issuer, expires => Expiry, hash => crypto:hash(sha256, Secret)},
            Invites = prune(maps:get(invitations, S)),
            #{<<"node">> := Name} = maps:get(Issuer, maps:get(<<"members">>, S)),
            Fields = #{<<"v">> => <<"1">>, <<"cluster">> => maps:get(<<"cluster">>, S),
                <<"issuer">> => Issuer, <<"node">> => Name, <<"invite">> => Id,
                <<"secret">> => Secret, <<"expires">> => Expiry},
            case map_size(Invites) < 256 of
                true ->
                    Next = S#{invitations := Invites#{Id => Entry}},
                    ok = parvi_cluster_store:save(authority, Next),
                    {reply, {ok, parvi_cluster_auth:invitation(Fields)}, Next};
                false -> {reply, {error, invitation_limit}, S#{invitations := Invites}}
            end
    end;
handle_call({claim, Issuer, Invite, Secret, Client, Name}, {Caller, _}, S)
        when is_binary(Issuer), is_binary(Invite), byte_size(Invite) =:= 32,
             is_binary(Secret), byte_size(Secret) =:= 64, is_binary(Client),
             byte_size(Client) =:= 64, is_binary(Name) ->
    Invites = prune(maps:get(invitations, S)),
    Valid = case maps:find(Invite, Invites) of
        {ok, #{issuer := Issuer, hash := Hash}} ->
            caller(Issuer, Caller, S) andalso crypto:hash_equals(Hash, crypto:hash(sha256, Secret));
        _ -> false
    end,
    Members = maps:get(<<"members">>, S),
    Unique = lists:all(fun({P, M}) -> P =:= Client orelse maps:get(<<"node">>, M) =/= Name end,
                       maps:to_list(Members)),
    SameName = case maps:find(Client, Members) of
        {ok, #{<<"node">> := Name}} -> true; error -> true; _ -> false
    end,
    case Valid andalso Unique andalso SameName andalso parvi_cluster_auth:valid_name(Name) andalso
            byte_size(Client) =:= 64 andalso (map_size(Members) < 64 orelse maps:is_key(Client, Members)) of
        false -> {reply, {error, invalid_invitation}, S#{invitations := Invites}};
        true ->
            Member = maps:get(Client, Members, #{<<"node">> => Name,
                <<"membership">> => parvi_cluster_auth:fresh(16), <<"via">> => Invite}),
            Next = S#{<<"members">> := Members#{Client => Member}, invitations := Invites,
                      <<"revision">> := maps:get(<<"revision">>, S) + 1},
            %% A retry may already have checkpointed this claimant. It receives
            %% policy in the grant; asking it to acknowledge over distribution
            %% before granting the connection creates a circular wait.
            %% Offline members reconcile additive, same-epoch revisions on
            %% reconnect. Their absence must not prevent a new admission.
            Connected = [atom_to_binary(N) || N <- [node() | nodes()]],
            Recipients = [P || {P,#{<<"node">> := N}} <- maps:to_list(Members),
                              P =/= Client, lists:member(N,Connected)],
            case publish(Next, Recipients) of
                ok -> {reply, {ok, public(Next)}, Next};
                error -> {reply, {error, policy_sync_incomplete}, Next}
            end
    end;
handle_call({member, Issuer, Client, Name}, {Caller, _}, S) ->
    Allowed = caller(Issuer, Caller, S) andalso
        case maps:find(Client, maps:get(<<"members">>, S)) of
            {ok, #{<<"node">> := Name}} -> true; _ -> false
        end,
    {reply, case Allowed of true -> {ok, public(S)}; false -> {error, not_a_member} end, S};
handle_call({remove_both, Actor, Target}, {Caller, _}, S) ->
    Members = maps:get(<<"members">>, S),
    Survivors = maps:without([Actor, Target], Members),
    case caller(Actor, Caller, S) andalso Actor =/= Target andalso maps:is_key(Target, Members)
            andalso reachable(Survivors) of
        false -> {reply, {error, removal_unavailable}, S};
        true ->
            Removed = [Actor, Target],
            Via = [maps:get(<<"via">>, maps:get(P, Members)) || P <- Removed],
            Invites = maps:filter(fun(Id, #{issuer := Issuer}) ->
                not lists:member(Issuer, Removed) andalso not lists:member(Id, Via)
            end, prune(maps:get(invitations, S))),
            Next = S#{<<"members">> := Survivors, invitations := Invites,
                <<"revision">> := maps:get(<<"revision">>, S) + 1,
                <<"epoch">> := maps:get(<<"epoch">>, S) + 1},
            Owner = atom_to_binary(node()),
            case lists:any(fun(M) -> maps:get(<<"node">>, M) =:= Owner end, maps:values(Survivors)) of
                true ->
                    Result = publish(Next, maps:keys(Survivors)),
                    Reply = case Result of ok -> {ok, complete}; error -> {error, policy_sync_incomplete} end,
                    {reply, Reply, Next};
                false when map_size(Survivors) > 0 ->
                    [NewOwner | _] = lists:sort([maps:get(<<"node">>, M) || M <- maps:values(Survivors)]),
                    Transfer = Next#{<<"authority">> := NewOwner, finalize => true},
                    %% The survivor owns completion, even when fencing disconnects this caller.
                    Result = try erpc:call(binary_to_existing_atom(NewOwner), parvi_cluster_trust,
                        take_over, [Transfer], 5000) catch _:_ -> pending end,
                    {stop, normal, {ok, Result}, S};
                false ->
                    [retire(maps:get(<<"node">>, maps:get(P, Members))) || P <- Removed],
                    {stop, normal, {ok, empty}, Next}
            end
    end;
handle_call(_, _, S) -> {reply, {error, unsupported}, S}.
handle_cast(stop, S) -> {stop, normal, S}.
handle_info(publish, S) ->
    _ = publish(S, maps:keys(maps:get(<<"members">>, S))), {noreply, S};
handle_info(_, S) -> {noreply, S}.

caller(Public, Pid, S) ->
    case maps:find(Public, maps:get(<<"members">>, S)) of
        {ok, #{<<"node">> := N}} -> N =:= atom_to_binary(node(Pid));
        _ -> false
    end.
prune(Invites) -> maps:filter(fun(_, #{expires := E}) -> E > erlang:system_time(second) end, Invites).
reachable(Members) ->
    Connected = [atom_to_binary(N) || N <- [node() | nodes(connected)]],
    lists:all(fun(#{<<"node">> := N}) -> lists:member(N, Connected) end, maps:values(Members)).
publish(S, Publics) ->
    ok = parvi_cluster_store:save(authority, S),
    Members = maps:get(<<"members">>, S),
    Results = [try
        Name = maps:get(<<"node">>, maps:get(P, Members)),
        case Name =:= atom_to_binary(node()) of
            true -> parvi_cluster_trust:install(public(S));
            false -> erpc:call(binary_to_existing_atom(Name), parvi_cluster_trust, install, [public(S)], 5000)
        end
    catch _:_ -> error end || P <- Publics],
    case lists:all(fun(R) -> R =:= ok end, Results) of true -> ok; false -> error end.
retire(Name) ->
    case Name =:= atom_to_binary(node()) of
        true -> parvi_cluster_trust:retire();
        false -> try erpc:call(binary_to_existing_atom(Name), parvi_cluster_trust, retire, [], 1000)
                 catch _:_ -> pending end
    end.
