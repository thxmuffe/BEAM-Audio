%% Historical app path: independent Buffee memberships; transport is trusted local distribution or
%% authenticated capability-addressed relay. Nodes own membership and history.
-module(ba_buffees).
-behaviour(gen_server).
-export([start_link/0, snapshot/0, create/1, join/3, send/2, leave/1, remove_both/2, join_relay/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

start_link() -> gen_server:start_link(ba_session_scope:registration(?MODULE), ?MODULE, [], []).
snapshot() ->
    try gen_server:call(ba_session_scope:ref(?MODULE), snapshot)
    catch exit:_ -> [] end.
create(Name) -> gen_server:call(ba_session_scope:ref(?MODULE), {create, Name}).
join(Node, Id, Token) -> gen_server:call(ba_session_scope:ref(?MODULE), {join, Node, Id, Token}, 6000).
send(Id, Text) -> connected_call({send, Id, Text}).
leave(Id) -> connected_call({leave, Id}).
remove_both(Id, Target) -> connected_call({remove_both, Id, Target}).
join_relay(Invitation) -> gen_server:call(ba_session_scope:ref(?MODULE), {join_relay, Invitation}, 8000).
connected_call(Command) ->
    case ba_relay:enabled() andalso not maps:get(connected, ba_relay:status())
         andalso ba_direct:peers() =:= [] of
        true -> {error, <<"Reception disconnected. Wait for reconnection.">>};
        false -> gen_server:call(ba_session_scope:ref(?MODULE), Command)
    end.

init([]) ->
    Initial = new_buffee(<<>>),
    {ok, #{buffees => #{maps:get(id, Initial) => Initial}, order => [maps:get(id, Initial)], next => 2, pending => #{}}}.

handle_call(Request, From, S) -> changed(handle_call_event(Request, From, S), S).

handle_call_event(health, _, State) -> {reply, #{node => identity()}, State};
handle_call_event(snapshot, _, #{buffees := Buffees, order := Order} = State) ->
    {reply, [view(maps:get(Id, Buffees)) || Id <- Order, active(maps:get(Id, Buffees))], State};
handle_call_event({create, _}, _, #{buffees := Buffees} = State) when map_size(Buffees) >= 64 ->
    {reply, {error, <<"This prototype supports 64 Buffee sessions per Device. Restart for a fresh session.">>}, State};
handle_call_event({create, Name}, _, #{buffees := Buffees, order := Order, next := Next} = State) ->
    Title = case Name of
        <<>> -> iolist_to_binary(io_lib:format("Buffee ~B", [Next]));
        _ -> Name
    end,
    case valid_text(Title, 80) of
        true ->
            Buffee = new_buffee(Title), Id = maps:get(id, Buffee),
            {reply, {ok, Id}, State#{buffees := Buffees#{Id => Buffee}, order := Order ++ [Id], next := Next + 1}};
        false -> {reply, {error, <<"Use a Buffee name of 1–80 UTF-8 bytes.">>}, State}
    end;
handle_call_event({join_relay, #{node := Owner, buffee := Id, token := Token, mailbox := Cap}}, From, #{pending := Pending, buffees := Buffees} = State) ->
    case find_active(Id, State) of
        {ok, _} -> {reply, {ok, Id}, State};
        error when map_size(Pending) < 16, map_size(Buffees) < 64; map_size(Pending) < 16, is_map_key(Id, Buffees) ->
            Member = new_member(Token), Request = fresh(),
            ba_relay:open(Id, maps:get(mailbox, Member)),
            case relay_send(Owner, Cap, Id, {join_request, Request, Token, Member}) of
                ok ->
                    Timer = erlang:send_after(6000, self(), {join_timeout, Request}),
                    Entry = #{from => From, owner => Owner, member => Member, buffee => Id, timer => Timer},
                    {noreply, State#{pending := Pending#{Request => Entry}}};
                _ -> ba_relay:close(maps:get(mailbox, Member)), {reply, {error, <<"Reception is not connected.">>}, State}
            end;
        error -> {reply, {error, <<"Buffee session or pending admission limit reached.">>}, State}
    end;
handle_call_event({join, Node, Id, Token}, _, State) ->
    case find_active(Id, State) of
        {ok, _} -> {reply, {ok, Id}, State};
        error ->
            Member = new_member(Token),
            Reply = try gen_server:call({?MODULE, Node}, {admit, Id, Token, Member}, 4000)
                    catch exit:_ -> {error, <<"The inviting node is unavailable. Ask another member for an invitation.">>} end,
            case Reply of
                {ok, Shared, Links} ->
                    %% Prototype distribution still uses trusted local peer links.
                    %% Establish those independently of logical Buffee membership.
                    [connect_member(Link) || Link <- Links],
                    Existing = maps:get(Id, maps:get(buffees, State), Shared),
                    Combined = merge(Existing, Shared),
                    Members = maps:get(members, Combined),
                    case maps:find(identity(), Members) of
                        {ok, #{id := Membership}} when Membership =:= map_get(id, Member) ->
                            Local = renew(Combined#{token => fresh(), history => queue:new(), count => 0}),
                            {reply, {ok, Id}, put_buffee(Local, State)};
                        _ -> {reply, {error, <<"Membership changed while joining. Ask for a fresh invitation.">>}, State}
                    end;
                {error, _} = Error -> {reply, Error, State};
                _ -> {reply, {error, <<"The invitation was not accepted.">>}, State}
            end
    end;
handle_call_event({admit, Id, Token, Member}, {Caller, _}, State) ->
    case find_active(Id, State) of
        {ok, #{token := Token} = Buffee} when node(Caller) =:= map_get(node, Member) ->
            case valid_member(Member) andalso not lists:member(Token, maps:get(revoked, Buffee)) of
                true ->
                    Members = maps:get(members, Buffee),
                    %% A restarted worker may need fresh admission on the same
                    %% runtime node. Replace its old membership, never duplicate it.
                    Removed = case maps:find(node(Caller), Members) of
                        {ok, Old} -> lists:usort([maps:get(id, Old) | maps:get(removed, Buffee)]);
                        error -> maps:get(removed, Buffee)
                    end,
                    Joined = Buffee#{members := Members#{node(Caller) => Member}, removed := Removed},
                    broadcast(Joined, {membership, own_id(Buffee), public(Joined)}),
                    Links = [connection(N) || N <- maps:keys(Members)],
                    {reply, {ok, public(Joined), [L || L <- Links, is_binary(L)]}, put_buffee(Joined, State)};
                false -> {reply, expired(), State}
            end;
        _ -> {reply, expired(), State}
    end;
handle_call_event({send, Id, Text}, _, State) ->
    case {find_active(Id, State), valid_text(Text, 4096)} of
        {{ok, Buffee}, true} ->
            Message = #{version => 1, id => fresh(), sender => identity(), text => Text,
                        sent_at_ms => erlang:system_time(millisecond)},
            broadcast(Buffee, {chat, Id, own_id(Buffee), Message}),
            {reply, ok, put_buffee(record(Message, Buffee), State)};
        {error, _} -> {reply, {error, <<"You are no longer in this Buffee.">>}, State};
        _ -> {reply, {error, <<"Use 1–4096 bytes of UTF-8 text.">>}, State}
    end;
handle_call_event({leave, Id}, _, State) ->
    case find_active(Id, State) of
        {ok, Buffee} -> depart(Buffee, [own_id(Buffee)], [], State);
        error -> {reply, {error, <<"You are no longer in this Buffee.">>}, State}
    end;
handle_call_event({remove_both, Id, Target}, _, State) ->
    case find_active(Id, State) of
        {ok, Buffee} ->
            Members = maps:get(members, Buffee),
            Matches = [M || M <- maps:values(Members), name(maps:get(node, M)) =:= Target,
                            maps:get(node, M) =/= identity()],
            case Matches of
                [Other] ->
                    Own = maps:get(identity(), Members),
                    Revoked = [T || #{via := T} <- [Own, Other], is_binary(T)],
                    depart(Buffee, [maps:get(id, Own), maps:get(id, Other)], Revoked, State);
                _ -> {reply, {error, <<"Select another current member of this Buffee.">>}, State}
            end;
        error -> {reply, {error, <<"You are no longer in this Buffee.">>}, State}
    end;
handle_call_event(_, _, State) -> {reply, {error, unsupported_request}, State}.

handle_cast(Message, S) -> changed(handle_cast_event(Message, S), S).

handle_cast_event({membership, Sender, Shared}, State) ->
    Id = maps:get(id, Shared),
    case find_active(Id, State) of
        {ok, Buffee} ->
            case known(Sender, Buffee) of
                true -> {noreply, put_buffee(renew(merge(Buffee, Shared)), State)};
                false -> {noreply, State}
            end;
        error -> {noreply, State}
    end;
handle_cast_event({departure, Id, Sender, Removed, Revoked}, State) ->
    case find_active(Id, State) of
        {ok, Buffee} ->
            case known(Sender, Buffee) andalso lists:member(Sender, Removed) of
                true ->
                    Next = apply_departure(Buffee, Removed, Revoked),
                    {noreply, put_buffee(renew(Next), State)};
                false -> {noreply, State}
            end;
        error -> {noreply, State}
    end;
handle_cast_event({chat, Id, Sender, #{sender := Node, text := Text} = Message}, State) ->
    case find_active(Id, State) of
        {ok, Buffee} ->
            case maps:find(Node, maps:get(members, Buffee)) of
                {ok, #{id := Sender}} ->
                    case valid_text(Text, 4096) of
                        true -> {noreply, put_buffee(record(Message, Buffee), State)};
                        false -> {noreply, State}
                    end;
                _ -> {noreply, State}
            end;
        error -> {noreply, State}
    end;
handle_cast_event(_, State) -> {noreply, State}.
handle_info(Message, S) -> changed(handle_info_event(Message, S), S).

handle_info_event({relay, connected}, #{buffees := Buffees} = State) ->
    [broadcast(W, {membership, own_id(W), public(W)}) || W <- maps:values(Buffees), active(W)],
    {noreply, State};
handle_info_event({relay, {delivery, Source, {join_request, Id, Request, Token, #{node := Source} = Member}}}, State) ->
    case find_active(Id, State) of
        {ok, #{token := Token} = Buffee} ->
            Members = maps:get(members, Buffee),
            case map_size(Members) < 64 andalso length(maps:get(removed, Buffee)) < 1024 andalso
                 not lists:member(Token, maps:get(revoked, Buffee)) andalso Source =/= identity() of
                true ->
                    Removed = case maps:find(Source, Members) of
                        {ok, Old} -> lists:usort([maps:get(id, Old) | maps:get(removed, Buffee)]);
                        error -> maps:get(removed, Buffee)
                    end,
                    Joined = Buffee#{members := Members#{Source => Member}, removed := Removed},
                    broadcast(Joined, {membership, own_id(Buffee), public(Joined)}),
                    relay_send(Source, maps:get(mailbox, Member), Id, {join_reply, Request, {ok, public(Joined)}}),
                    {noreply, put_buffee(Joined, State)};
                false ->
                    relay_send(Source, maps:get(mailbox, Member), Id, {join_reply, Request, expired()}), {noreply, State}
            end;
        _ -> relay_send(Source, maps:get(mailbox, Member), Id, {join_reply, Request, expired()}), {noreply, State}
    end;
handle_info_event({relay, {delivery, Source, {join_reply, Id, Request, Reply}}}, #{pending := Pending} = State) ->
    case maps:find(Request, Pending) of
        {ok, #{owner := Source, buffee := Id} = Entry} -> finish_join(Request, Entry, Reply, State);
        _ -> {noreply, State}
    end;
handle_info_event({relay, {delivery, Source, {rtc, Id, Sender, Signal}}}, State) ->
    case source_member(Source, Sender, Id, State) of
        true -> ba_direct:incoming(Source, Signal);
        false -> ok
    end,
    {noreply, State};
handle_info_event({relay, {delivery, Source, Event}}, State) ->
    case authenticated_event(Source, Event, State) of true -> handle_cast(Event, State); false -> {noreply, State} end;
handle_info_event({relay, {error, Request, _}}, #{pending := Pending} = State) ->
    case maps:find(Request, Pending) of
        {ok, Entry} -> finish_join(Request, Entry, {error, <<"Inviting node or mailbox is unavailable.">>}, State);
        error -> {noreply, State}
    end;
handle_info_event({join_timeout, Request}, #{pending := Pending} = State) ->
    case maps:find(Request, Pending) of
        {ok, Entry} -> finish_join(Request, Entry, {error, <<"Invitation timed out. Ask a connected member for a fresh invitation.">>}, State);
        error -> {noreply, State}
    end;
handle_info_event(_, State) -> {noreply, State}.

finish_join(Request, #{from := From, member := Member, timer := Timer, buffee := Id}, Reply, #{pending := Pending} = State) ->
    erlang:cancel_timer(Timer), S = State#{pending := maps:remove(Request, Pending)},
    case Reply of
        {ok, Shared} ->
            Existing = maps:get(Id, maps:get(buffees, S), Shared), Combined = merge(Existing, Shared),
            case maps:find(identity(), maps:get(members, Combined)) of
                {ok, Member} ->
                    Local = renew(Combined#{token => fresh(), history => queue:new(), count => 0}),
                    gen_server:reply(From, {ok, Id}), {noreply, put_buffee(Local, S)};
                _ -> finish_failed(From, Member, S)
            end;
        {error, Error} ->
            gen_server:reply(From, {error, Error}), ba_relay:close(maps:get(mailbox, Member)), {noreply, S}
    end.
finish_failed(From, Member, S) ->
    gen_server:reply(From, {error, <<"Membership changed during admission.">>}),
    ba_relay:close(maps:get(mailbox, Member)), {noreply, S}.
authenticated_event(Source, {membership, Sender, #{id := Id}}, State) -> source_member(Source, Sender, Id, State);
authenticated_event(Source, {departure, Id, Sender, _, _}, State) -> source_member(Source, Sender, Id, State);
authenticated_event(Source, {chat, Id, Sender, #{sender := Source}}, State) -> source_member(Source, Sender, Id, State);
authenticated_event(_, _, _) -> false.
source_member(Source, Sender, Id, State) ->
    case find_active(Id, State) of
        {ok, Buffee} -> case maps:find(Source, maps:get(members, Buffee)) of {ok, #{id := Sender}} -> true; _ -> false end;
        error -> false
    end.
relay_send(To, Cap, Id, Event) -> ba_relay:send(To, Cap, ba_buffee_wire:encode(Id, Event)).
identity() -> ba_relay:id().
name(N) when is_atom(N) -> atom_to_binary(N);
name(N) -> N.
new_member(Via) ->
    M = #{id => fresh(), node => identity(), via => Via},
    case ba_relay:enabled() of true -> M#{mailbox => fresh()}; false -> M end.


new_buffee(Name) ->
    Id = fresh(),
    Title = case Name of <<>> -> <<"Buffee ", (binary:part(Id, 0, 4))/binary>>; _ -> Name end,
    Member = new_member(none),
    case ba_relay:enabled() of true -> ba_relay:open(Id, maps:get(mailbox, Member)); false -> ok end,
    #{id => Id, name => Title, token => fresh(),
      members => #{identity() => Member},
      removed => [], revoked => [], history => queue:new(), count => 0}.

fresh() -> binary:encode_hex(crypto:strong_rand_bytes(16)).
active(Buffee) -> maps:is_key(identity(), maps:get(members, Buffee)).
own_id(Buffee) -> maps:get(id, maps:get(identity(), maps:get(members, Buffee))).
known(Id, Buffee) -> lists:any(fun(#{id := I}) -> I =:= Id end, maps:values(maps:get(members, Buffee))).
find_active(Id, #{buffees := Buffees}) ->
    case maps:find(Id, Buffees) of
        {ok, Buffee} -> case active(Buffee) of true -> {ok, Buffee}; false -> error end;
        error -> error
    end.

put_buffee(#{id := Id} = Buffee, #{buffees := Buffees, order := Order} = State) ->
    NextOrder = case lists:member(Id, Order) of true -> Order; false -> Order ++ [Id] end,
    Next = State#{buffees := Buffees#{Id => Buffee}, order := NextOrder},
    case ba_relay:enabled() of
        true ->
            case {active(Buffee), maps:find(Id, Buffees)} of
                {false, {ok, Old}} ->
                    case maps:find(identity(), maps:get(members, Old)) of
                        {ok, #{mailbox := Cap}} -> ba_relay:close(Cap); _ -> ok
                    end;
                _ -> ok
            end,
            ba_relay:watch(lists:usort(lists:append([maps:keys(maps:get(members, W)) || W <- maps:values(maps:get(buffees, Next)), active(W)])));
        false -> ok
    end,
    sync_direct(Next), Next.

sync_direct(#{buffees := Buffees}) ->
    Routes = lists:foldl(fun(W, Acc) ->
        case active(W) andalso ba_relay:enabled() of
            false -> Acc;
            true ->
                Id = maps:get(id, W),
                lists:foldl(fun({N, M}, A) ->
                    case N =/= identity() andalso is_binary(N) of
                        false -> A;
                        true -> Cap = maps:get(mailbox, M),
                            maps:update_with(N, fun(R) -> R#{mailboxes := (maps:get(mailboxes, R))#{Id => Cap}} end,
                                #{buffee => Id, mailbox => Cap, member => own_id(W), mailboxes => #{Id => Cap}}, A)
                    end
                end, Acc, maps:to_list(maps:get(members, W)))
        end
    end, #{}, maps:values(Buffees)),
    ba_direct:sync(Routes).

public(Buffee) -> maps:with([id, name, members, removed, revoked], Buffee).
broadcast(Buffee, Event) ->
    [case N of
        _ when is_atom(N) -> gen_server:cast({?MODULE, N}, Event);
        _ ->
            Id = maps:get(id, Buffee), Cap = maps:get(mailbox, M),
            Payload = ba_buffee_wire:encode(Id, Event),
            case ba_direct:send(N, Cap, Payload) of
                ok -> ok;
                _ -> ba_relay:send(N, Cap, Payload)
            end
     end || {N, M} <- maps:to_list(maps:get(members, Buffee)), N =/= identity()], ok.

merge(Local, Remote) ->
    Removed = lists:usort(maps:get(removed, Local) ++ maps:get(removed, Remote)),
    Members = maps:merge(maps:get(members, Local), maps:get(members, Remote)),
    Local#{members := maps:filter(fun(_, #{id := I}) -> not lists:member(I, Removed) end, Members),
           removed := Removed,
           revoked := lists:usort(maps:get(revoked, Local) ++ maps:get(revoked, Remote))}.

renew(#{token := Token} = Buffee) ->
    case active(Buffee) andalso lists:member(Token, maps:get(revoked, Buffee)) of
        true -> Buffee#{token := fresh()};
        false -> Buffee
    end.

apply_departure(Buffee, Removed, Revoked) ->
    merge(Buffee, (public(Buffee))#{removed := Removed, revoked := Revoked}).

depart(Buffee, Removed, Revoked, State) ->
    broadcast(Buffee, {departure, maps:get(id, Buffee), own_id(Buffee), Removed, Revoked}),
    Next = apply_departure(Buffee, Removed, Revoked),
    {reply, ok, put_buffee(Next, State)}.

record(Message, #{history := History, count := Count} = Buffee) ->
    case lists:any(fun(M) -> maps:get(id, M) =:= maps:get(id, Message) end, queue:to_list(History)) of
        true -> Buffee;
        false -> record_new(Message, History, Count, Buffee)
    end.
record_new(Message, History, Count, Buffee) ->
    Added = queue:in(Message, History),
    case Count >= 200 of
        true -> Buffee#{history := queue:drop(Added)};
        false -> Buffee#{history := Added, count := Count + 1}
    end.

view(Buffee) ->
    Members = maps:values(maps:get(members, Buffee)),
    #{id => maps:get(id, Buffee), name => maps:get(name, Buffee),
      invitation => case ba_relay:enabled() of
          true -> ba_invitation:relay(maps:get(id, Buffee), maps:get(token, Buffee), maps:get(mailbox, maps:get(identity(), maps:get(members, Buffee))));
          false -> case identity() of nonode@nohost -> null; _ -> ba_invitation:format(maps:get(id, Buffee), maps:get(token, Buffee)) end
      end,
      members => [name(maps:get(node, M)) || M <- Members],
      messages => [#{id => maps:get(id, M), sender => name(maps:get(sender, M)),
                     text => maps:get(text, M), time => maps:get(sent_at_ms, M)} || M <- queue:to_list(maps:get(history, Buffee))]}.

valid_text(Text, Limit) when is_binary(Text), byte_size(Text) > 0, byte_size(Text) =< Limit ->
    unicode:characters_to_binary(Text, utf8, utf8) =:= Text;
valid_text(_, _) -> false.
valid_member(#{id := Id, node := Node, via := Via}) -> is_binary(Id) andalso (is_atom(Node) orelse is_binary(Node)) andalso is_binary(Via);
valid_member(_) -> false.
expired() -> {error, <<"This invitation has expired or its member has left. Ask for a fresh invitation.">>}.

connection(N) ->
    try erpc:call(N, ba_legacy_connection, local, [], 500)
    catch _:_ -> unavailable end.

connect_member(Link) ->
    case ba_legacy_connection:parse(Link) of
        {ok, #{node := Name, cookie := Cookie}} ->
            %% Names come from already authenticated prototype peers, not a directory.
            Node = binary_to_existing_atom(Name),
            erlang:set_cookie(Node, binary_to_atom(Cookie, utf8)),
            net_adm:ping(Node);
        _ -> unavailable
    end.

changed({reply,Reply,Next}, Old) ->
    notify_changed(Old,Next), {reply,Reply,Next};
changed({noreply,Next}, Old) ->
    notify_changed(Old,Next), {noreply,Next};
changed(Result, _) -> Result.
notify_changed(Old,Next) ->
    View = fun(S) -> S end,
    case View(Old) =:= View(Next) of
        true -> ok; false -> ba_events:notify(buffees)
    end.
