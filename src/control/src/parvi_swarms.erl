%% Independent swarm memberships; transport is trusted local distribution or
%% authenticated capability-addressed relay. Nodes own membership and history.
-module(parvi_swarms).
-behaviour(gen_server).
-export([start_link/0, snapshot/0, create/1, join/3, send/2, leave/1, remove_both/2, join_relay/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).
snapshot() ->
    try gen_server:call(?MODULE, snapshot)
    catch exit:_ -> [] end.
create(Name) -> gen_server:call(?MODULE, {create, Name}).
join(Node, Id, Token) -> gen_server:call(?MODULE, {join, Node, Id, Token}, 6000).
send(Id, Text) -> connected_call({send, Id, Text}).
leave(Id) -> connected_call({leave, Id}).
remove_both(Id, Target) -> connected_call({remove_both, Id, Target}).
join_relay(Invitation) -> gen_server:call(?MODULE, {join_relay, Invitation}, 8000).
connected_call(Command) ->
    case parvi_relay:enabled() andalso not maps:get(connected, parvi_relay:status())
         andalso parvi_direct:peers() =:= [] of
        true -> {error, <<"Reception desk disconnected. Wait for reconnection.">>};
        false -> gen_server:call(?MODULE, Command)
    end.

init([]) ->
    Initial = new_swarm(<<>>),
    {ok, #{swarms => #{maps:get(id, Initial) => Initial}, order => [maps:get(id, Initial)], next => 2, pending => #{}}}.

handle_call(health, _, State) -> {reply, #{node => identity()}, State};
handle_call(snapshot, _, #{swarms := Swarms, order := Order} = State) ->
    {reply, [view(maps:get(Id, Swarms)) || Id <- Order, active(maps:get(Id, Swarms))], State};
handle_call({create, _}, _, #{swarms := Swarms} = State) when map_size(Swarms) >= 64 ->
    {reply, {error, <<"This prototype supports 64 swarm sessions per node. Restart for a fresh session.">>}, State};
handle_call({create, Name}, _, #{swarms := Swarms, order := Order, next := Next} = State) ->
    Title = case Name of
        <<>> -> iolist_to_binary(io_lib:format("Swarm ~B", [Next]));
        _ -> Name
    end,
    case valid_text(Title, 80) of
        true ->
            Swarm = new_swarm(Title), Id = maps:get(id, Swarm),
            {reply, {ok, Id}, State#{swarms := Swarms#{Id => Swarm}, order := Order ++ [Id], next := Next + 1}};
        false -> {reply, {error, <<"Use a swarm name of 1–80 UTF-8 bytes.">>}, State}
    end;
handle_call({join_relay, #{node := Owner, swarm := Id, token := Token, mailbox := Cap}}, From, #{pending := Pending, swarms := Swarms} = State) ->
    case find_active(Id, State) of
        {ok, _} -> {reply, {ok, Id}, State};
        error when map_size(Pending) < 16, map_size(Swarms) < 64; map_size(Pending) < 16, is_map_key(Id, Swarms) ->
            Member = new_member(Token), Request = fresh(),
            parvi_relay:open(Id, maps:get(mailbox, Member)),
            case relay_send(Owner, Cap, Id, {join_request, Request, Token, Member}) of
                ok ->
                    Timer = erlang:send_after(6000, self(), {join_timeout, Request}),
                    Entry = #{from => From, owner => Owner, member => Member, swarm => Id, timer => Timer},
                    {noreply, State#{pending := Pending#{Request => Entry}}};
                _ -> parvi_relay:close(maps:get(mailbox, Member)), {reply, {error, <<"Reception desk is not connected.">>}, State}
            end;
        error -> {reply, {error, <<"Swarm session or pending admission limit reached.">>}, State}
    end;
handle_call({join, Node, Id, Token}, _, State) ->
    case find_active(Id, State) of
        {ok, _} -> {reply, {ok, Id}, State};
        error ->
            Member = new_member(Token),
            Reply = try gen_server:call({?MODULE, Node}, {admit, Id, Token, Member}, 4000)
                    catch exit:_ -> {error, <<"The inviting node is unavailable. Ask another member for an invitation.">>} end,
            case Reply of
                {ok, Shared, Links} ->
                    %% Prototype distribution still uses trusted local peer links.
                    %% Establish those independently of logical swarm membership.
                    [connect_member(Link) || Link <- Links],
                    Existing = maps:get(Id, maps:get(swarms, State), Shared),
                    Combined = merge(Existing, Shared),
                    Members = maps:get(members, Combined),
                    case maps:find(identity(), Members) of
                        {ok, #{id := Membership}} when Membership =:= map_get(id, Member) ->
                            Local = renew(Combined#{token => fresh(), history => queue:new(), count => 0}),
                            {reply, {ok, Id}, put_swarm(Local, State)};
                        _ -> {reply, {error, <<"Membership changed while joining. Ask for a fresh invitation.">>}, State}
                    end;
                {error, _} = Error -> {reply, Error, State};
                _ -> {reply, {error, <<"The invitation was not accepted.">>}, State}
            end
    end;
handle_call({admit, Id, Token, Member}, {Caller, _}, State) ->
    case find_active(Id, State) of
        {ok, #{token := Token} = Swarm} when node(Caller) =:= map_get(node, Member) ->
            case valid_member(Member) andalso not lists:member(Token, maps:get(revoked, Swarm)) of
                true ->
                    Members = maps:get(members, Swarm),
                    %% A restarted worker may need fresh admission on the same
                    %% runtime node. Replace its old membership, never duplicate it.
                    Removed = case maps:find(node(Caller), Members) of
                        {ok, Old} -> lists:usort([maps:get(id, Old) | maps:get(removed, Swarm)]);
                        error -> maps:get(removed, Swarm)
                    end,
                    Joined = Swarm#{members := Members#{node(Caller) => Member}, removed := Removed},
                    broadcast(Joined, {membership, own_id(Swarm), public(Joined)}),
                    Links = [connection(N) || N <- maps:keys(Members)],
                    {reply, {ok, public(Joined), [L || L <- Links, is_binary(L)]}, put_swarm(Joined, State)};
                false -> {reply, expired(), State}
            end;
        _ -> {reply, expired(), State}
    end;
handle_call({send, Id, Text}, _, State) ->
    case {find_active(Id, State), valid_text(Text, 4096)} of
        {{ok, Swarm}, true} ->
            Message = #{version => 1, id => fresh(), sender => identity(), text => Text,
                        sent_at_ms => erlang:system_time(millisecond)},
            broadcast(Swarm, {chat, Id, own_id(Swarm), Message}),
            {reply, ok, put_swarm(record(Message, Swarm), State)};
        {error, _} -> {reply, {error, <<"You are no longer in this swarm.">>}, State};
        _ -> {reply, {error, <<"Use 1–4096 bytes of UTF-8 text.">>}, State}
    end;
handle_call({leave, Id}, _, State) ->
    case find_active(Id, State) of
        {ok, Swarm} -> depart(Swarm, [own_id(Swarm)], [], State);
        error -> {reply, {error, <<"You are no longer in this swarm.">>}, State}
    end;
handle_call({remove_both, Id, Target}, _, State) ->
    case find_active(Id, State) of
        {ok, Swarm} ->
            Members = maps:get(members, Swarm),
            Matches = [M || M <- maps:values(Members), name(maps:get(node, M)) =:= Target,
                            maps:get(node, M) =/= identity()],
            case Matches of
                [Other] ->
                    Own = maps:get(identity(), Members),
                    Revoked = [T || #{via := T} <- [Own, Other], is_binary(T)],
                    depart(Swarm, [maps:get(id, Own), maps:get(id, Other)], Revoked, State);
                _ -> {reply, {error, <<"Select another current member of this swarm.">>}, State}
            end;
        error -> {reply, {error, <<"You are no longer in this swarm.">>}, State}
    end;
handle_call(_, _, State) -> {reply, {error, unsupported_request}, State}.

handle_cast({membership, Sender, Shared}, State) ->
    Id = maps:get(id, Shared),
    case find_active(Id, State) of
        {ok, Swarm} ->
            case known(Sender, Swarm) of
                true -> {noreply, put_swarm(renew(merge(Swarm, Shared)), State)};
                false -> {noreply, State}
            end;
        error -> {noreply, State}
    end;
handle_cast({departure, Id, Sender, Removed, Revoked}, State) ->
    case find_active(Id, State) of
        {ok, Swarm} ->
            case known(Sender, Swarm) andalso lists:member(Sender, Removed) of
                true ->
                    Next = apply_departure(Swarm, Removed, Revoked),
                    {noreply, put_swarm(renew(Next), State)};
                false -> {noreply, State}
            end;
        error -> {noreply, State}
    end;
handle_cast({chat, Id, Sender, #{sender := Node, text := Text} = Message}, State) ->
    case find_active(Id, State) of
        {ok, Swarm} ->
            case maps:find(Node, maps:get(members, Swarm)) of
                {ok, #{id := Sender}} ->
                    case valid_text(Text, 4096) of
                        true -> {noreply, put_swarm(record(Message, Swarm), State)};
                        false -> {noreply, State}
                    end;
                _ -> {noreply, State}
            end;
        error -> {noreply, State}
    end;
handle_cast(_, State) -> {noreply, State}.
handle_info({relay, connected}, #{swarms := Swarms} = State) ->
    [broadcast(W, {membership, own_id(W), public(W)}) || W <- maps:values(Swarms), active(W)],
    {noreply, State};
handle_info({relay, {delivery, Source, {join_request, Id, Request, Token, #{node := Source} = Member}}}, State) ->
    case find_active(Id, State) of
        {ok, #{token := Token} = Swarm} ->
            Members = maps:get(members, Swarm),
            case map_size(Members) < 64 andalso length(maps:get(removed, Swarm)) < 1024 andalso
                 not lists:member(Token, maps:get(revoked, Swarm)) andalso Source =/= identity() of
                true ->
                    Removed = case maps:find(Source, Members) of
                        {ok, Old} -> lists:usort([maps:get(id, Old) | maps:get(removed, Swarm)]);
                        error -> maps:get(removed, Swarm)
                    end,
                    Joined = Swarm#{members := Members#{Source => Member}, removed := Removed},
                    broadcast(Joined, {membership, own_id(Swarm), public(Joined)}),
                    relay_send(Source, maps:get(mailbox, Member), Id, {join_reply, Request, {ok, public(Joined)}}),
                    {noreply, put_swarm(Joined, State)};
                false ->
                    relay_send(Source, maps:get(mailbox, Member), Id, {join_reply, Request, expired()}), {noreply, State}
            end;
        _ -> relay_send(Source, maps:get(mailbox, Member), Id, {join_reply, Request, expired()}), {noreply, State}
    end;
handle_info({relay, {delivery, Source, {join_reply, Id, Request, Reply}}}, #{pending := Pending} = State) ->
    case maps:find(Request, Pending) of
        {ok, #{owner := Source, swarm := Id} = Entry} -> finish_join(Request, Entry, Reply, State);
        _ -> {noreply, State}
    end;
handle_info({relay, {delivery, Source, {rtc, Id, Sender, Signal}}}, State) ->
    case source_member(Source, Sender, Id, State) of
        true -> parvi_direct:incoming(Source, Signal);
        false -> ok
    end,
    {noreply, State};
handle_info({relay, {delivery, Source, Event}}, State) ->
    case authenticated_event(Source, Event, State) of true -> handle_cast(Event, State); false -> {noreply, State} end;
handle_info({relay, {error, Request, _}}, #{pending := Pending} = State) ->
    case maps:find(Request, Pending) of
        {ok, Entry} -> finish_join(Request, Entry, {error, <<"Inviting node or mailbox is unavailable.">>}, State);
        error -> {noreply, State}
    end;
handle_info({join_timeout, Request}, #{pending := Pending} = State) ->
    case maps:find(Request, Pending) of
        {ok, Entry} -> finish_join(Request, Entry, {error, <<"Invitation timed out. Ask a connected member for a fresh invitation.">>}, State);
        error -> {noreply, State}
    end;
handle_info(_, State) -> {noreply, State}.

finish_join(Request, #{from := From, member := Member, timer := Timer, swarm := Id}, Reply, #{pending := Pending} = State) ->
    erlang:cancel_timer(Timer), S = State#{pending := maps:remove(Request, Pending)},
    case Reply of
        {ok, Shared} ->
            Existing = maps:get(Id, maps:get(swarms, S), Shared), Combined = merge(Existing, Shared),
            case maps:find(identity(), maps:get(members, Combined)) of
                {ok, Member} ->
                    Local = renew(Combined#{token => fresh(), history => queue:new(), count => 0}),
                    gen_server:reply(From, {ok, Id}), {noreply, put_swarm(Local, S)};
                _ -> finish_failed(From, Member, S)
            end;
        {error, Error} ->
            gen_server:reply(From, {error, Error}), parvi_relay:close(maps:get(mailbox, Member)), {noreply, S}
    end.
finish_failed(From, Member, S) ->
    gen_server:reply(From, {error, <<"Membership changed during admission.">>}),
    parvi_relay:close(maps:get(mailbox, Member)), {noreply, S}.
authenticated_event(Source, {membership, Sender, #{id := Id}}, State) -> source_member(Source, Sender, Id, State);
authenticated_event(Source, {departure, Id, Sender, _, _}, State) -> source_member(Source, Sender, Id, State);
authenticated_event(Source, {chat, Id, Sender, #{sender := Source}}, State) -> source_member(Source, Sender, Id, State);
authenticated_event(_, _, _) -> false.
source_member(Source, Sender, Id, State) ->
    case find_active(Id, State) of
        {ok, Swarm} -> case maps:find(Source, maps:get(members, Swarm)) of {ok, #{id := Sender}} -> true; _ -> false end;
        error -> false
    end.
relay_send(To, Cap, Id, Event) -> parvi_relay:send(To, Cap, parvi_swarm_wire:encode(Id, Event)).
identity() -> parvi_relay:id().
name(N) when is_atom(N) -> atom_to_binary(N);
name(N) -> N.
new_member(Via) ->
    M = #{id => fresh(), node => identity(), via => Via},
    case parvi_relay:enabled() of true -> M#{mailbox => fresh()}; false -> M end.


new_swarm(Name) ->
    Id = fresh(),
    Title = case Name of <<>> -> <<"Swarm ", (binary:part(Id, 0, 4))/binary>>; _ -> Name end,
    Member = new_member(none),
    case parvi_relay:enabled() of true -> parvi_relay:open(Id, maps:get(mailbox, Member)); false -> ok end,
    #{id => Id, name => Title, token => fresh(),
      members => #{identity() => Member},
      removed => [], revoked => [], history => queue:new(), count => 0}.

fresh() -> binary:encode_hex(crypto:strong_rand_bytes(16)).
active(Swarm) -> maps:is_key(identity(), maps:get(members, Swarm)).
own_id(Swarm) -> maps:get(id, maps:get(identity(), maps:get(members, Swarm))).
known(Id, Swarm) -> lists:any(fun(#{id := I}) -> I =:= Id end, maps:values(maps:get(members, Swarm))).
find_active(Id, #{swarms := Swarms}) ->
    case maps:find(Id, Swarms) of
        {ok, Swarm} -> case active(Swarm) of true -> {ok, Swarm}; false -> error end;
        error -> error
    end.

put_swarm(#{id := Id} = Swarm, #{swarms := Swarms, order := Order} = State) ->
    NextOrder = case lists:member(Id, Order) of true -> Order; false -> Order ++ [Id] end,
    Next = State#{swarms := Swarms#{Id => Swarm}, order := NextOrder},
    case parvi_relay:enabled() of
        true ->
            case {active(Swarm), maps:find(Id, Swarms)} of
                {false, {ok, Old}} ->
                    case maps:find(identity(), maps:get(members, Old)) of
                        {ok, #{mailbox := Cap}} -> parvi_relay:close(Cap); _ -> ok
                    end;
                _ -> ok
            end,
            parvi_relay:watch(lists:usort(lists:append([maps:keys(maps:get(members, W)) || W <- maps:values(maps:get(swarms, Next)), active(W)])));
        false -> ok
    end,
    sync_direct(Next), Next.

sync_direct(#{swarms := Swarms}) ->
    Routes = lists:foldl(fun(W, Acc) ->
        case active(W) andalso parvi_relay:enabled() of
            false -> Acc;
            true ->
                Id = maps:get(id, W),
                lists:foldl(fun({N, M}, A) ->
                    case N =/= identity() andalso is_binary(N) of
                        false -> A;
                        true -> Cap = maps:get(mailbox, M),
                            maps:update_with(N, fun(R) -> R#{mailboxes := (maps:get(mailboxes, R))#{Id => Cap}} end,
                                #{swarm => Id, mailbox => Cap, member => own_id(W), mailboxes => #{Id => Cap}}, A)
                    end
                end, Acc, maps:to_list(maps:get(members, W)))
        end
    end, #{}, maps:values(Swarms)),
    parvi_direct:sync(Routes).

public(Swarm) -> maps:with([id, name, members, removed, revoked], Swarm).
broadcast(Swarm, Event) ->
    [case N of
        _ when is_atom(N) -> gen_server:cast({?MODULE, N}, Event);
        _ ->
            Id = maps:get(id, Swarm), Cap = maps:get(mailbox, M),
            Payload = parvi_swarm_wire:encode(Id, Event),
            case parvi_direct:send(N, Cap, Payload) of
                ok -> ok;
                _ -> parvi_relay:send(N, Cap, Payload)
            end
     end || {N, M} <- maps:to_list(maps:get(members, Swarm)), N =/= identity()], ok.

merge(Local, Remote) ->
    Removed = lists:usort(maps:get(removed, Local) ++ maps:get(removed, Remote)),
    Members = maps:merge(maps:get(members, Local), maps:get(members, Remote)),
    Local#{members := maps:filter(fun(_, #{id := I}) -> not lists:member(I, Removed) end, Members),
           removed := Removed,
           revoked := lists:usort(maps:get(revoked, Local) ++ maps:get(revoked, Remote))}.

renew(#{token := Token} = Swarm) ->
    case active(Swarm) andalso lists:member(Token, maps:get(revoked, Swarm)) of
        true -> Swarm#{token := fresh()};
        false -> Swarm
    end.

apply_departure(Swarm, Removed, Revoked) ->
    merge(Swarm, (public(Swarm))#{removed := Removed, revoked := Revoked}).

depart(Swarm, Removed, Revoked, State) ->
    broadcast(Swarm, {departure, maps:get(id, Swarm), own_id(Swarm), Removed, Revoked}),
    Next = apply_departure(Swarm, Removed, Revoked),
    {reply, ok, put_swarm(Next, State)}.

record(Message, #{history := History, count := Count} = Swarm) ->
    case lists:any(fun(M) -> maps:get(id, M) =:= maps:get(id, Message) end, queue:to_list(History)) of
        true -> Swarm;
        false -> record_new(Message, History, Count, Swarm)
    end.
record_new(Message, History, Count, Swarm) ->
    Added = queue:in(Message, History),
    case Count >= 200 of
        true -> Swarm#{history := queue:drop(Added)};
        false -> Swarm#{history := Added, count := Count + 1}
    end.

view(Swarm) ->
    Members = maps:values(maps:get(members, Swarm)),
    #{id => maps:get(id, Swarm), name => maps:get(name, Swarm),
      invitation => case parvi_relay:enabled() of
          true -> parvi_invitation:relay(maps:get(id, Swarm), maps:get(token, Swarm), maps:get(mailbox, maps:get(identity(), maps:get(members, Swarm))));
          false -> case identity() of nonode@nohost -> null; _ -> parvi_invitation:format(maps:get(id, Swarm), maps:get(token, Swarm)) end
      end,
      members => [name(maps:get(node, M)) || M <- Members],
      messages => [#{id => maps:get(id, M), sender => name(maps:get(sender, M)),
                     text => maps:get(text, M), time => maps:get(sent_at_ms, M)} || M <- queue:to_list(maps:get(history, Swarm))]}.

valid_text(Text, Limit) when is_binary(Text), byte_size(Text) > 0, byte_size(Text) =< Limit ->
    unicode:characters_to_binary(Text, utf8, utf8) =:= Text;
valid_text(_, _) -> false.
valid_member(#{id := Id, node := Node, via := Via}) -> is_binary(Id) andalso (is_atom(Node) orelse is_binary(Node)) andalso is_binary(Via);
valid_member(_) -> false.
expired() -> {error, <<"This invitation has expired or its member has left. Ask for a fresh invitation.">>}.

connection(N) ->
    try erpc:call(N, parvi_connection, local, [], 500)
    catch _:_ -> unavailable end.

connect_member(Link) ->
    case parvi_connection:parse(Link) of
        {ok, #{node := Name, cookie := Cookie}} ->
            %% Names come from already authenticated prototype peers, not a directory.
            Node = binary_to_existing_atom(Name),
            erlang:set_cookie(Node, binary_to_atom(Cookie, utf8)),
            net_adm:ping(Node);
        _ -> unavailable
    end.
