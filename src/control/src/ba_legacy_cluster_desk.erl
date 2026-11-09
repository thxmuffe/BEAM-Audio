%% Historical trusted-app/Distributed Erlang path; not the secure Swarm API.
%% Desk introductions only. OTP traffic stays on the WebRTC carrier.
%% Start after net_kernel; supervised by the Mac native runtime profile.
-module(ba_legacy_cluster_desk).
-behaviour(gen_server).
-export([start_link/0, create/0, invite/1, invitation/0, join/1, connect_member/1, forget/0, status/0, network_changed/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).
create() -> gen_server:call(?MODULE, create).
invite(TTL) -> gen_server:call(?MODULE, {invite, TTL}).
invitation() -> gen_server:call(?MODULE, invitation).
join(Link) -> gen_server:call(?MODULE, {join, Link}).
connect_member(Name) ->
    case ba_node_api:invitation(Name) of
        {ok,Link} -> gen_server:call(?MODULE,{connect_member,Link});
        Error -> Error
    end.
forget() -> gen_server:call(?MODULE, forget).
status() -> gen_server:call(?MODULE, status).
network_changed() -> gen_server:cast(?MODULE, network_changed).

init([]) ->
    process_flag(trap_exit, true),
    {ok, _} = application:ensure_all_started(ba_transport),
    {ok, Trust} = ba_legacy_cluster_trust:start_link(self()),
    {ok, Relay} = ba_relay:start_link(#{owner => self(), delivery => raw}),
    Saved = ba_device_store:load(desk,
        #{mailbox => ba_legacy_cluster_auth:fresh(16), peers => #{}, cluster => undefined}),
    ok = ba_device_store:save(desk, Saved),
    ok = net_kernel:monitor_nodes(true),
    State = Saved#{trust => Trust, relay => Relay, cluster := undefined,
        sessions => #{}, event => starting, invitation => undefined,
        online => [], retry => undefined, backoff => 500},
    {ok, refresh(State)}.

handle_call(Request, From, S) -> changed(handle_call_event(Request, From, S), S).

handle_call_event(create, _, #{cluster := undefined} = S) ->
    {ok, Policy} = ba_legacy_cluster_trust:create(),
    {reply, {ok, Policy}, mailbox(maps:get(<<"cluster">>, Policy), S)};
handle_call_event(invitation, _, S) ->
    Policy = ba_legacy_cluster_trust:policy(),
    case {Policy, maps:get(connected, ba_relay:status()), authority_online(Policy)} of
        {#{<<"cluster">> := Cluster, <<"epoch">> := Epoch}, true, true} ->
            Now = erlang:system_time(second),
            case maps:get(invitation, S) of
                {Cluster, Epoch, Expiry, Link} when Expiry > Now -> {reply, {ok, Link}, S};
                _ ->
                    case make_invitation(259200, S) of
                        {ok, Link} -> {reply, {ok, Link}, S#{invitation := {Cluster, Epoch, Now + 259200, Link}}};
                        Error -> {reply, Error, S}
                    end
            end;
        _ -> {reply, {error, not_ready}, S}
    end;
handle_call_event({invite, TTL}, _, #{cluster := Cluster} = S) when is_binary(Cluster) ->
    Reply = case {maps:get(connected, ba_relay:status()), authority_online(ba_legacy_cluster_trust:policy())} of
        {false, _} -> {error, desk_disconnected};
        {true, false} -> {error, authority_offline};
        {true, true} ->
            make_invitation(TTL, S)
    end,
    {reply, Reply, S};
handle_call_event({join, Link}, _, #{cluster := undefined} = S) ->
    case parse_link(Link) of
        {ok, Peer, Cap, Cluster, Invitation} ->
            case maps:get(connected, ba_relay:status()) of
                false -> {reply, {error, desk_disconnected}, S};
                true ->
                    Id = ba_legacy_cluster_auth:fresh(16),
                    case channel(Id, Peer, Cap, {join, Invitation}, S) of
                        {ok, Next} ->
                            Open = mailbox(Cluster, Next),
                            Result = send(Peer, Cap, Id, #{<<"kind">> => <<"hello">>}, Open),
                            {reply, Result, maps:remove(last_rejection, Open)};
                        {error, Reason} -> {reply, {error, Reason}, S}
                    end
            end;
        Error -> {reply, Error, S}
    end;
handle_call_event({join, Link}, From, #{sessions := Sessions} = S) when map_size(Sessions) =:= 0 ->
    %% A timed-out first admission reserved a mailbox, not membership. Release
    %% that failed attempt so the user can retry after the desk/peer recovers.
    case ba_legacy_cluster_trust:policy() of
        undefined -> handle_call({join, Link}, From, refresh(S));
        _ -> {reply, {error, already_clustered_or_not_created}, S}
    end;
handle_call_event({connect_member,Link}, _, #{sessions := Sessions} = S) ->
    try
        #{<<"cluster">> := Cluster,<<"members">> := Members} = ba_legacy_cluster_trust:policy(),
        {ok,Peer,Cap,Cluster,_} = parse_link(Link),
        #{<<"node">> := Name} = maps:get(Peer,Members),
        Existing = lists:member(Name,[atom_to_binary(N) || N <- nodes()]) orelse
            lists:any(fun(#{peer := P}) -> P =:= Peer end,maps:values(Sessions)),
        case Existing of
            true -> {reply,ok,S};
            false ->
                Id = ba_legacy_cluster_auth:fresh(16),
                case channel(Id,Peer,Cap,{member,Peer},S) of
                    {ok,Next} -> {reply,send(Peer,Cap,Id,#{<<"kind">> => <<"hello">>},Next),Next};
                    Error -> {reply,Error,S}
                end
        end
    catch _:_ -> {reply,{error,source_member_unavailable},S} end;
handle_call_event(status, _, S) ->
    {reply, #{desk => ba_relay:status(), connected_nodes => nodes(),
              policy => ba_legacy_cluster_trust:policy(), event => maps:get(event, S),
              last_rejection => maps:get(last_rejection,S,null)}, S};
handle_call_event(forget, _, S) ->
    ok = ba_legacy_cluster_trust:retire(),
    {reply, ok, refresh(S)};
handle_call_event(_, _, S) -> {reply, {error, already_clustered_or_not_created}, S}.
handle_cast(network_changed, S) ->
    %% Coalesce path updates; retain all durable membership and identity state.
    case maps:get(network_change,S,undefined) of
        undefined ->
            Tag = make_ref(),
            erlang:send_after(500,self(),{network_changed,Tag}),
            {noreply,S#{network_change => Tag}};
        _ -> {noreply,S}
    end;
handle_cast(_, S) -> {noreply, S}.

handle_info(Message, S) -> changed(handle_info_event(Message, S), S).

handle_info_event({network_changed,Tag}, #{network_change := Tag,sessions := Sessions} = S) ->
    case maps:get(retry,S) of undefined -> ok; Ref -> erlang:cancel_timer(Ref) end,
    maps:foreach(fun(_,Route) ->
        case maps:get(node,Route,undefined) of
            undefined -> ok; Node -> erlang:disconnect_node(Node)
        end,
        exit(maps:get(ctrl,Route),{shutdown,network_changed})
    end,Sessions),
    ba_relay:reconnect(),
    case whereis(ba_audio_receiver) of
        undefined -> ok; _ -> ba_audio_receiver:network_changed()
    end,
    {noreply,S#{network_change := undefined,sessions := #{},online := [],
        retry := undefined,backoff := 500,event := network_changed}};
handle_info_event({relay, {delivery, From, Cap, Payload}}, #{mailbox := Cap} = S) ->
    {noreply, incoming(From, Payload, S)};
handle_info_event({relay, {presence, Online}}, S) ->
    {noreply, reconnect(S#{online := Online, backoff := 500})};
handle_info_event({relay, connected}, S) ->
    {noreply, refresh(S#{event := {desk, connected}})};
handle_info_event({relay, disconnected}, S) ->
    {noreply, S#{online := [], event := {desk, disconnected}}};
handle_info_event({relay, {error, Id, <<"unavailable">>}}, #{sessions := Sessions} = S) ->
    case maps:find(Id, Sessions) of
        {ok, #{ctrl := Ctrl}} ->
            exit(Ctrl, {shutdown, peer_unavailable}), {noreply, S};
        error -> {noreply, S#{event := {desk, {error, Id, <<"unavailable">>}}}}
    end;
handle_info_event({relay, Event}, S) -> {noreply, S#{event := {desk, Event}}};
handle_info_event({trust, policy_changed}, S) -> {noreply, refresh(S)};
handle_info_event(reconnect, S) -> {noreply, reconnect(S#{retry := undefined})};
handle_info_event({nodedown, Node}, #{sessions := Sessions} = S) ->
    %% Distribution reports failure; permission and remembered routes survive.
    [exit(Ctrl, {shutdown, nodedown}) || #{ctrl := Ctrl, node := N} <- maps:values(Sessions), N =:= Node],
    {noreply, schedule(S)};
handle_info_event({nodeup, Node}, S) -> {noreply, S#{event := {native_connected, Node, true}}};
handle_info_event({channel, Ctrl, {signal, Signal}}, #{sessions := Sessions} = S) ->
    case route(Ctrl, Sessions) of
        [#{id := Id, peer := Peer, mailbox := Cap}] ->
            Result = send(Peer, Cap, Id, Signal, S),
            {noreply, S#{event := {signalling, Result}}};
        [] -> {noreply, S}
    end;
handle_info_event({trust, Ctrl, authorized, Node}, #{sessions := Sessions} = S) ->
    case route(Ctrl, Sessions) of
        [#{role := server}] -> ok = ba_webrtc_dist:admit(Ctrl);
        [#{role := Role}] when element(1, Role) =:= join; element(1, Role) =:= member ->
            Owner = self(),
            spawn(fun() -> Owner ! {native_connected, Ctrl, Node, net_kernel:connect_node(Node)} end);
        [] -> ok
    end,
    {noreply, remember(Ctrl, Node, S#{event := {authorized, Node}})};
handle_info_event({trust, _, rejected, Reason}, S) -> {noreply, S#{event := {rejected, Reason}, last_rejection => Reason}};
handle_info_event({native_connected, Ctrl, Node, Result}, #{sessions := Sessions} = S) ->
    %% An older attempt must not close a replacement session or overwrite its
    %% nodeup status. The controller identifies the exact connection attempt.
    case route(Ctrl, Sessions) of
        [] -> {noreply, S};
        [_] when Result =:= false ->
            exit(Ctrl, {shutdown, distribution_failed}),
            Event = case lists:member(Node, nodes()) of
                true -> {native_connected, Node, true};
                false -> {native_connected, Node, false}
            end,
            {noreply, schedule(S#{event := Event})};
        [_] -> {noreply, S#{event := {native_connected, Node, Result}}}
    end;
handle_info_event({'EXIT', Pid, Reason}, #{trust := Pid} = S) -> {stop, {trust_stopped, Reason}, S};
handle_info_event({'EXIT', Pid, Reason}, #{relay := Pid} = S) -> {stop, {relay_stopped, Reason}, S};
handle_info_event({'EXIT', Pid, Reason}, #{sessions := Sessions} = S) ->
    case route(Pid, Sessions) of
        [] -> {noreply, S};
        [#{peer := Peer} = Route] ->
            Kept = maps:filter(fun(_, #{ctrl := Ctrl}) -> Ctrl =/= Pid end, Sessions),
            %% A setup attempt can end before authorization assigns its OTP
            %% node. Its remembered peer still identifies the affected member.
            Remembered = maps:get(Peer, maps:get(peers, S), #{}),
            Node = maps:get(node, Route, maps:get(node, Remembered, undefined)),
            Event = {channel_stopped, Node, Reason},
            {noreply, schedule(S#{sessions := Kept, event := Event})}
    end;
handle_info_event(_, S) -> {noreply, S}.

mailbox(Cluster, S) ->
    ba_relay:open(Cluster, maps:get(mailbox, S)), S#{cluster := Cluster}.

channel(Id, Peer, Cap, Role, #{sessions := Sessions} = S) ->
    Ice = application:get_env(ba_transport, native_ice_servers,
        [#{urls => application:get_env(ba_core, direct_stun_urls, [])}]),
    {ok, Ctrl} = ba_dist_channel:start_link(self(), Role =:= server, Ice),
    case ba_legacy_cluster_trust:attach(Ctrl, Role) of
        ok ->
            Route = #{id => Id, ctrl => Ctrl, peer => Peer, mailbox => Cap, role => Role},
            {ok, S#{sessions := Sessions#{Id => Route}}};
        {error, Reason} -> gen_server:stop(Ctrl), {error, Reason}
    end.

incoming(From, #{<<"type">> := <<"otp_signal">>, <<"swarm">> := Cluster,
                 <<"connection">> := Id, <<"reply">> := Cap, <<"signal">> := Signal},
         #{cluster := Cluster, sessions := Sessions} = S) ->
    case maps:find(Id, Sessions) of
        {ok, #{peer := From, mailbox := Cap}} when Signal =:= #{<<"kind">> => <<"hello">>} -> S;
        {ok, #{peer := From, mailbox := Cap, ctrl := Ctrl}} ->
            ba_dist_channel:signal(Ctrl, Signal), S;
        error when Signal =:= #{<<"kind">> => <<"hello">>} ->
            case channel(Id, From, Cap, server, S) of
                {ok, Next} -> Next;
                {error, Reason} -> S#{event := {rejected, Reason}}
            end;
        _ -> S
    end;
incoming(_, _, S) -> S.

route(Ctrl, Sessions) -> [R || R = #{ctrl := P} <- maps:values(Sessions), P =:= Ctrl].

send(Peer, Cap, Id, Signal, S) ->
    ba_relay:send(Peer, Cap, #{<<"type">> => <<"otp_signal">>,
        <<"swarm">> => maps:get(cluster, S), <<"connection">> => Id,
        <<"request">> => Id, <<"reply">> => maps:get(mailbox, S), <<"signal">> => Signal}).

parse_link(Link) ->
    try
        #{scheme := <<"parvi">>, host := <<"cluster">>, path := <<"/v2">>, query := Query} =
            uri_string:parse(string:trim(Link)),
        #{<<"desk">> := URL, <<"node">> := Peer, <<"mailbox">> := Cap,
          <<"invitation">> := Invitation} = maps:from_list(uri_string:dissect_query(Query)),
        true = ba_relay:valid_url(URL), URL = ba_relay:url(),
        32 = byte_size(binary:decode_hex(Peer)), 16 = byte_size(binary:decode_hex(Cap)),
        {ok, #{<<"cluster">> := Cluster}} = ba_legacy_cluster_auth:parse_invitation(Invitation),
        {ok, Peer, Cap, Cluster, Invitation}
    catch _:_ -> {error, invalid_invitation_or_different_desk} end.

terminate(_, #{trust := Trust, relay := Relay}) ->
    %% Closing the app releases runtime resources, not durable membership.
    case whereis(ba_legacy_cluster_authority) of
        undefined -> ok;
        Authority -> try gen_server:stop(Authority) catch exit:_ -> ok end
    end,
    [try gen_server:stop(Pid) catch exit:_ -> ok end || Pid <- [Trust, Relay]], ok.

make_invitation(TTL, S) ->
    case ba_legacy_cluster_trust:invite(TTL) of
        {ok, Invitation} ->
            Query = uri_string:compose_query([
                {<<"desk">>, ba_relay:url()}, {<<"node">>, ba_relay:id()},
                {<<"mailbox">>, maps:get(mailbox, S)}, {<<"invitation">>, Invitation}]),
            {ok, <<"parvi://cluster/v2?", Query/binary>>};
        Error -> Error
    end.

refresh(#{peers := Peers, cluster := Previous} = S) ->
    case ba_legacy_cluster_trust:policy() of
        undefined ->
            ba_relay:close(maps:get(mailbox, S)), ba_relay:watch([]),
            save(S#{cluster := undefined, peers := #{}, invitation := undefined});
        #{<<"cluster">> := Cluster, <<"members">> := Members} ->
            Kept = maps:filter(fun(_, #{member := Member}) -> maps:is_key(Member, Members) end, Peers),
            Next = mailbox(Cluster, S#{peers := Kept}),
            ba_relay:watch(maps:keys(Kept)),
            save(case Previous =:= Cluster of true -> Next; false -> Next#{invitation := undefined} end)
    end.

remember(Ctrl, Node, #{sessions := Sessions, peers := Peers} = S) ->
    case {route(Ctrl, Sessions), ba_legacy_cluster_trust:policy()} of
        {[#{id := Id, peer := Peer, mailbox := Cap} = Route], #{<<"members">> := Members}} ->
            case [Key || {Key, #{<<"node">> := Name}} <- maps:to_list(Members), Name =:= atom_to_binary(Node)] of
                [Member] ->
                    Next = save(S#{peers := Peers#{Peer => #{mailbox => Cap, member => Member, node => atom_to_binary(Node)}},
                                   sessions := Sessions#{Id := Route#{node => Node}}}),
                    ba_relay:watch(maps:keys(maps:get(peers, Next))), Next;
                [] -> S
            end;
        _ -> S
    end.

save(S) ->
    ok = ba_device_store:save(desk, maps:with([cluster, mailbox, peers], S)), S.

reconnect(#{peers := Peers, sessions := Sessions, online := Online} = S) ->
    Self = ba_relay:id(),
    Missing = [{Peer, Route} || {Peer, Route = #{node := Name}} <- maps:to_list(Peers),
        Peer < Self, lists:member(Peer, Online),
        not lists:member(Name, [atom_to_binary(N) || N <- nodes()]),
        not lists:any(fun(#{peer := P}) -> P =:= Peer end, maps:values(Sessions))],
    Next = lists:foldl(fun({Peer, #{mailbox := Cap, member := Member}}, Acc) ->
        Id = ba_legacy_cluster_auth:fresh(16),
        case channel(Id, Peer, Cap, {member, Member}, Acc) of
            {ok, Open} ->
                _ = send(Peer, Cap, Id, #{<<"kind">> => <<"hello">>}, Open), Open;
            {error, Reason} -> Acc#{event := {rejected, Reason}}
        end
    end, S, Missing),
    case Missing of [] -> Next; _ -> schedule(Next) end.

schedule(#{retry := undefined, backoff := Delay} = S) ->
    Ref = erlang:send_after(Delay, self(), reconnect),
    S#{retry := Ref, backoff := min(10000, Delay * 2)};
schedule(S) -> S.

authority_online(#{<<"authority">> := Authority}) ->
    lists:member(Authority, [atom_to_binary(N) || N <- [node() | nodes()]]);
authority_online(_) -> false.

changed({reply,Reply,Next}, Old) ->
    notify_changed(Old,Next), {reply,Reply,Next};
changed({noreply,Next}, Old) ->
    notify_changed(Old,Next), {noreply,Next};
changed(Result, _) -> Result.
notify_changed(Old,Next) ->
    View = fun(S) -> maps:with([event,cluster,peers],S) end,
    case View(Old) =:= View(Next) of
        true -> ok; false -> ba_events:notify(cluster)
    end.
