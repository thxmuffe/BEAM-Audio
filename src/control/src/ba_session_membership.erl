%% Session rights. There is no membership list: holding the link lets a Device
%% sign its own join certificate with the invitation key, and every request
%% carries it (ba_session_control_protocol). Nobody needs to know who else is in
%% the Session. Privileges are a signed, versioned statement that grant holders
%% change; it travels to the Devices it concerns and spreads on contact, the
%% newer side sharing it. The highest revision wins.
-module(ba_session_membership).
-behaviour(gen_server).
-export([announce/1,start_link/0,status/0,current/0,invite/1,invite_devices/2,grant/2,revoke/1,grant_privilege/2,take_privilege/2,decline_privilege/2,request_privilege/1,end_session/0,rename/1,resend_chat/0]).
-export([init/1,handle_call/3,handle_cast/2,handle_info/2,format_status/1]).
-ifdef(TEST).
-export([order/3]).
-endif.
-define(LOOKUP_MS,2000).
%% Devices this one has dealt with, most recent first.
-define(ENCOUNTERED,64).
%% Devices Reception reports reachable on the Session mailbox (a neighbour source).
-define(REACHABLE,32).
%% Gossip a signed note (e.g. on_air) to the whole Session through neighbours.
announce(Kind) -> gen_server:cast(ba_session_scope:ref(?MODULE),{announce,Kind}).
rename(Name) -> gen_server:call(ba_session_scope:ref(?MODULE),{rename,Name}).
request_privilege(Wire) -> gen_server:call(ba_session_scope:ref(?MODULE),{request_privilege,Wire}).
grant_privilege(Device,Wire) -> gen_server:call(ba_session_scope:ref(?MODULE),{change,grant,Device,Wire}).
take_privilege(Device,Wire) -> gen_server:call(ba_session_scope:ref(?MODULE),{change,take,Device,Wire}).
end_session() -> gen_server:call(ba_session_scope:ref(?MODULE),end_session).
decline_privilege(Device,Wire) -> gen_server:call(ba_session_scope:ref(?MODULE),{decline,Device,Wire}).
start_link() -> gen_server:start_link(ba_session_scope:registration(?MODULE),?MODULE,[],[]).
status() -> gen_server:call(ba_session_scope:ref(?MODULE),status).
current() -> gen_server:call(ba_session_scope:ref(?MODULE),current).
invite(TTL) -> gen_server:call(ba_session_scope:ref(?MODULE),{invite,TTL}).
invite_devices(Ids,TTL) -> gen_server:call(ba_session_scope:ref(?MODULE),{invite_devices,Ids,TTL}).
grant(Device,Permissions) -> gen_server:call(ba_session_scope:ref(?MODULE),{grant,Device,Permissions}).
revoke(Device) -> gen_server:call(ba_session_scope:ref(?MODULE),{revoke,Device}).

init([]) ->
    {Pub,Private} = ba_device_store:identity(),Id = binary:encode_hex(Pub),
    {ok,Config} = ba_session_scope:get_env(session_membership),
    S = boot(Config,#{id => Id,private => Private,rejected => 0}),
    erlang:send_after(250,self(),tick),{ok,S}.
%% Creating writes the permanent link; the creator then participates like anyone.
boot(#{mode := create,name := Name,desks := URLs} = Config,#{id := Id} = S) ->
    ok = ba_session_passport:urls(URLs),true = valid_name(Name),
    Nonce = maps:get(nonce,Config,fresh(16)),Session = ba_session_passport:session_id(Id,Nonce),
    case maps:find(session,Config) of {ok,Wanted} -> Session = Wanted;error -> ok end,
    I = #{<<"v">> => 1,<<"type">> => <<"invitation">>,<<"session">> => Session,<<"authority">> => Id,
          <<"nonce">> => Nonce,<<"secret">> => fresh(16),<<"desks">> => URLs,<<"name">> => Name},
    Started = start(ba_session_passport:link(I),I,maps:get(desk,Config,hd(URLs)),S),
    %% The link carries no name: sign the starting policy so joiners learn it.
    case maps:get(signed,Started) of
        undefined -> {ok,Signed} = update(fun(P) -> {ok,P} end,Started),Signed;
        _ -> Started
    end;
boot(#{mode := join,invitation := Link} = Config,S) ->
    {_,I} = ba_session_passport:parse_invitation(Link),
    start(Link,I,maps:get(desk,Config,hd(maps:get(<<"desks">>,I))),S);
boot(#{mode := resume},_S) ->
    error(ephemeral_sessions_cannot_be_resumed).
start(Link,I,Primary,S) ->
    Session = maps:get(<<"session">>,I),URLs = maps:get(<<"desks">>,I),true = lists:member(Primary,URLs),
    Secret = maps:get(<<"secret">>,I),
    {Invitation,InvitationKey} = ba_session_passport:invitation_key(Secret),
    Base = S#{envelope => ba_session_passport:envelope_key(Secret),invitation => Invitation,join => ba_session_passport:join(Session,maps:get(id,S),InvitationKey),link => Link,session => Session,authority => maps:get(<<"authority">>,I),secret => Secret,
        cap => ba_session_passport:mailbox(Secret),name => maps:get(<<"name">>,I),urls => URLs,primary => Primary,
        policy => ba_session_passport:genesis(I,defaults()),signed => undefined,signer => undefined,delegations => #{},
        reachable => #{},encountered => [],board => ba_session_board:new(),seen => #{},
        state => authorized,until => infinity,last_lookup => now_ms()-?LOOKUP_MS},
    Ready = restore(maps:get(Session,ba_device_store:load(saved_sessions,#{}),undefined),Base),
    ok = ba_session_desks:configure(Session,URLs,Primary,#{}),
    ok = ba_session_desks:advertise(maps:get(cap,Ready)),
    checkpoint(Ready),self_check(publish(Ready)).
%% This Device's own record: the policy it last accepted.
restore(#{signer := Signer,signed := Packet},S) ->
    try St = ba_session_passport:statement(Packet,Signer),
        true = same_session(maps:get(<<"policy">>,St),S),adopt(Signer,Packet,St,S)
    catch _:_ -> S end;
restore(_,S) -> S.

handle_call(status,_,#{policy := P}=S) ->
    {reply,#{id => maps:get(id,S),session => maps:get(session,S),privileges => local_privileges(S),grant_holders => holders(P),
        name => maps:get(name,S),owner => maps:get(authority,S),requests => open_requests(S),
        state => maps:get(state,S),grant_holder_present => grant_holder_present(S),epoch => null,
        revision => maps:get(<<"revision">>,P),members => known(S),participants => reachable(S),
        membership => null,rejected => maps:get(rejected,S)},S};
handle_call(current,_,#{state := authorized} = S) -> {reply,{ok,view(S)},S};
handle_call(current,_,S) -> {reply,{error,maps:get(state,S)},S};
%% Every participant holds the same permanent link and may share it.
handle_call({invite,_},_,S) -> {reply,{ok,maps:get(link,S)},S};
handle_call({invite_devices,Ids,_},_,S) when is_list(Ids),length(Ids)>0,length(Ids)=<15 ->
    case lists:all(fun(Id) -> Id=:=undefined orelse ba_hex:valid(Id,64) end,Ids) of
        false -> {reply,{error,invalid_invitation},S};
        true ->
            %% Explicitly inviting a removed contact lifts the removal; forwarding does not.
            Lift = [Id || Id <- Ids,Id=/=undefined,lists:member(Id,removed(S))],
            Next = case Lift=/=[] andalso grant_holder(S) of
                true -> update(fun(P) -> {ok,P#{<<"removed">> := maps:get(<<"removed">>,P)--Lift}} end,S);
                false -> {ok,S}
            end,
            case Next of
                {ok,S1} -> {reply,{ok,[#{device => Id,invitation => maps:get(link,S)} || Id <- Ids]},S1};
                Error -> {reply,Error,S}
            end
    end;
handle_call({invite_devices,_,_},_,S) -> {reply,{error,invalid_invitation},S};
handle_call(end_session,_,#{state := authorized,policy := P}=S) ->
    case ba_session_privileges:has(end_session,maps:get(id,S),P) of
        false -> {reply,{error,end_privilege_required},S};
        true ->
            ba_session_control:session_request(contacts(S),#{<<"kind">> => <<"ended">>}),
            {reply,ok,S}
    end;
handle_call(end_session,_,S) -> {reply,{error,end_privilege_required},S};
%% Leaving changes no signed state: Reception drops this Device's advertisement.
handle_call({rename,Name},_,#{state := authorized,policy := P,id := Id}=S) ->
    case {valid_name(Name),grant_holder(S),ba_session_privileges:has(on_air,Id,P)} of
        {false,_,_} -> {reply,{error,invalid_session_name},S};
        {true,true,_} -> reply(update(fun(Q) -> {ok,Q} end,S#{name := Name}),S);
        {true,false,true} -> {reply,ask_holders(#{<<"kind">> => <<"rename_request">>,<<"name">> => Name},S),S};
        {true,false,false} -> {reply,{error,forbidden},S}
    end;
%% Every privilege is requested. A grant holder's own request needs no one else;
%% anyone else posts a signed request on the board, which spreads by contact.
handle_call({request_privilege,Wire},From,#{id := Id}=S) ->
    case grant_holder(S) of
        true -> handle_call({change,grant,Id,Wire},From,S);
        false ->
            Entry = ba_session_board:request(maps:get(session,S),Id,maps:get(join,S),Wire,maps:get(private,S)),
            {Reply,Next} = post(Entry,S),
            chat({privilege_requested,Id,Wire}),
            {reply,Reply,Next}
    end;
%% A grant holder's decline is a signed board entry, so every copy closes it.
handle_call({decline,Device,Wire},_,S) ->
    case grant_holder(S) of
        true -> {reply,ok,answer(decline,Device,Wire,open_refs(Device,Wire,S),S)};
        false -> {reply,{error,grant_required},S}
    end;
handle_call({change,Op,Device,Wire},_,#{id := Id}=S) ->
    case grant_holder(S) of
        true ->
            case update(fun(P) -> case member(Device,P,S) of
                    {ok,Q} -> ba_session_privileges:change(Id,Device,Op,Wire,Q);
                    Error -> Error
                end end,S) of
                %% Granting answers the open requests for it, on every copy.
                {ok,Next} when Op=:=grant -> {reply,ok,answer(granted,Device,Wire,open_refs(Device,Wire,S),Next)};
                {ok,Next} -> {reply,ok,Next};
                Error -> {reply,Error,S}
            end;
        %% Any Device may give up its own privilege; a grant holder applies it.
        false when Op=:=take,Device=:=Id -> {reply,ask_holders(#{<<"kind">> => <<"privilege_release">>,<<"privilege">> => Wire},S),S};
        false -> {reply,{error,grant_required},S}
    end;
handle_call({grant,Device,Permissions},_,S) ->
    Result = try
        true = grant_holder(S),ok = ba_session_passport:permissions(Permissions),
        update(fun(P) -> {ok,Q} = member(Device,P,S),Members = maps:get(<<"members">>,Q),
            {ok,Q#{<<"members">> := Members#{Device := #{<<"permissions">> => Permissions}}}} end,S)
    catch exit:{membership_storage_failed,_} = Reason -> exit(Reason);
          _:_ -> {error,invalid_grant} end,
    case Result of {ok,Next} -> {reply,ok,Next};_ -> {reply,{error,invalid_grant},S} end;
handle_call({revoke,Device},_,#{id := Id,policy := Policy}=S) ->
    case {Device=/=Id andalso ba_hex:valid(Device,64),grant_holder(S),ba_session_privileges:has(end_session,Id,Policy)} of
        {false,_,_} -> {reply,{error,invalid_revocation},S};
        {true,false,false} -> {reply,{error,kick_privilege_required},S};
        %% The same signed End authorization can disconnect just one target.
        %% Do not require an Admin to be online for a live kick. Ask any present
        %% grant holder to record removal too, without granting policy-signing
        %% or privilege-management powers to the moderator.
        {true,false,true} ->
            Direct=ba_session_control:session_request([Device],#{<<"kind">> => <<"ended">>}),
            Recorded=ask_holders(#{<<"kind">> => <<"remove_request">>,<<"device">> => Device},S),
            Result=case {Direct,Recorded} of {ok,_} -> ok;{_,ok} -> ok;_ -> Recorded end,
            {reply,Result,S};
        {true,true,_} -> reply(update(fun(P) ->
            Manager = case maps:get(<<"manager">>,P) of Device -> maps:get(<<"authority">>,P);M -> M end,
            Removed = lists:usort([Device|maps:get(<<"removed">>,P)]),
            case length(Removed) =< 31 of
                true -> {ok,P#{<<"manager">> := Manager,<<"members">> := maps:remove(Device,maps:get(<<"members">>,P)),
                               <<"removed">> := Removed}};
                false -> {error,too_many_removed}
            end end,S),S)
    end;
handle_call(_,_,S) -> {reply,{error,unsupported},S}.
%% The chat starts after this process and may miss the first publish.
handle_cast(resend_chat,#{state := authorized}=S) -> chat_view(S),{noreply,S};
%% A Session request already authenticated and authorized per request by the
%% control protocol (ba_device_request). This Device approves and executes it.
handle_cast({session_request,Peer,Payload},#{state := authorized}=S) ->
    try {noreply,session_request(Peer,Payload,S)}
    catch exit:{membership_storage_failed,_}=Reason -> exit(Reason);
          _:_ -> {noreply,S#{rejected := maps:get(rejected,S)+1}}
    end;
handle_cast({announce,Kind},#{state := authorized,id := Id}=S) ->
    %% A bad announcement must never take down the Session's rights process.
    try ba_session_gossip:note(maps:get(session,S),Id,maps:get(join,S),Kind,maps:get(private,S)) of
        {NoteId,Packet} ->
            Note = #{<<"kind">> => <<"note">>,<<"id">> => NoteId,<<"packet">> => Packet},
            ba_session_control:session_request(contacts(S),Note),
            {noreply,S#{seen := (maps:get(seen,S))#{NoteId => erlang:system_time(second)}}}
    catch _:_ -> {noreply,S#{rejected := maps:get(rejected,S)+1}}
    end;
%% A Device this one dealt with; the side with the newer statement shares it.
handle_cast({encountered,Peer,Revision},#{state := authorized,policy := P}=S) ->
    Seen = lists:sublist([Peer|lists:delete(Peer,maps:get(encountered,S))],?ENCOUNTERED),
    case Revision < maps:get(<<"revision">>,P)+1 of true -> tell(Peer,S);false -> ok end,
    %% Anti-entropy: every new contact gets this Device's board.
    send_board(Peer,ba_session_board:entries(maps:get(board,S))),
    {noreply,publish(S#{encountered := Seen})};
%% A linked peer's packets show an older statement: it missed a change.
handle_cast({behind,Peer},#{state := authorized}=S) -> tell(Peer,S),{noreply,S};
handle_cast(_,S) -> {noreply,S}.

handle_info(tick,S0) ->
    Now = now_ms(),
    S2 = case Now-maps:get(last_lookup,S0) >= ?LOOKUP_MS of
        true -> Sec = erlang:system_time(second),
            check_in(discover(S0#{board := ba_session_board:expire(maps:get(board,S0),Sec),
                                  seen := ba_session_gossip:expire(maps:get(seen,S0),Sec)}));
        false -> S0
    end,
    erlang:send_after(250,self(),tick),{noreply,S2};
handle_info({desk_event,_,connected},S) ->
    %% Do not wait for the next lookup after a Desk becomes usable.
    {noreply,discover(S)};
handle_info({desk_event,_,_},S) -> {noreply,S};
handle_info({lookup,URL,{ok,Owners}},#{id := Id,reachable := Reachable}=S) when is_list(Owners) ->
    Present = [O || O <- lists:usort(Owners),O=/=Id,ba_hex:valid(O,64),not lists:member(O,removed(S))],
    %% A sticky random sample (peer sampling): keep neighbours still present,
    %% fill free places at random. Nobody needs the whole Session.
    Kept = [O || O <- maps:get(URL,Reachable,[]),lists:member(O,Present)],
    Fresh = [O || {_,O} <- lists:sort([{rand:uniform(),O} || O <- Present--Kept])],
    Found = lists:sort(lists:sublist(Kept++Fresh,?REACHABLE)),
    case maps:get(URL,Reachable,[])=:=Found of
        true -> {noreply,S};
        false -> {noreply,publish(S#{reachable := Reachable#{URL => Found}})}
    end;
handle_info({lookup,_,_},S) -> {noreply,S};
handle_info(_,S) -> {noreply,S}.

%% Reception lists Devices present on the Session mailbox: neighbours to reach,
%% not a membership list. Lookups run outside this process.
discover(#{state := authorized,urls := URLs,cap := Cap}=S) ->
    Self = self(),
    [ba_session_scope:spawn(fun() ->
        Self ! {lookup,URL,try ba_session_desks:lookup(URL,Cap) catch _:_ -> {error,unavailable} end}
    end) || URL <- URLs],
    S#{last_lookup := now_ms()};
discover(S) -> S#{last_lookup := now_ms()}.
%% Without a signed statement yet (just joined), introduce this Device to a
%% neighbour: the encounter makes the side with the newer statement share it,
%% and the request board syncs on the same contact.
check_in(#{state := authorized,signed := undefined}=S) ->
    case reachable(S) of
        [] -> ok;
        Neighbours -> ba_session_control:introduce(lists:nth(rand:uniform(length(Neighbours)),Neighbours))
    end,S;
check_in(S) -> S.
%% Execution of approved Session requests. Rights were checked by the control
%% protocol; only this Device's own ability to execute is checked here.
%% A gossiped note: act on it once and pass it on to the other neighbours.
session_request(Peer,#{<<"kind">> := <<"note">>,<<"id">> := NoteId,<<"packet">> := Packet}=Note,#{id := Id}=S) ->
    case maps:is_key(NoteId,maps:get(seen,S)) of
        true -> S;
        false ->
            {ok,#{<<"kind">> := Kind,<<"author">> := Author}} = ba_session_gossip:check(NoteId,Packet,board_context(S)),
            case {Kind,Author=:=Id} of
                {<<"on_air">>,false} -> notify_audio({on_air_announced,Author});
                _ -> ok
            end,
            [ba_session_control:session_request([D],Note) || D <- contacts(S),D=/=Peer,D=/=Author],
            S#{seen := (maps:get(seen,S))#{NoteId => erlang:system_time(second)}}
    end;
%% Board entries from a neighbour: keep the valid new ones, act on them, and
%% pass them on to the other neighbours.
session_request(Peer,#{<<"kind">> := <<"board">>,<<"entries">> := Packets},S) ->
    {New,Board} = ba_session_board:merge(Packets,board_context(S),maps:get(board,S)),
    Next = lists:foldl(fun(Id,Acc) -> learned(element(1,maps:get(Id,Board)),Acc) end,S#{board := Board},New),
    case New of
        [] -> Next;
        _ -> Out = maps:with(New,Packets),[send_board(D,Out) || D <- contacts(Next),D=/=Peer],Next
    end;
session_request(Peer,#{<<"kind">> := <<"privilege_release">>,<<"privilege">> := Wire},S) ->
    true = grant_holder(S),
    {reply,_,Next} = handle_call({change,take,Peer,Wire},undefined,S),Next;
session_request(_,#{<<"kind">> := <<"rename_request">>,<<"name">> := Name},S) ->
    true = grant_holder(S),
    {reply,_,Next} = handle_call({rename,Name},undefined,S),Next;
session_request(Peer,#{<<"kind">> := <<"remove_request">>,<<"device">> := Device},S) ->
    true = grant_holder(S),true = Device=/=Peer,
    {reply,_,Next} = handle_call({revoke,Device},undefined,S),Next;
session_request(_,#{<<"kind">> := <<"ended">>},S) ->
    invalidate(),ba_session:ended(self()),S#{state := ended,until := 0};
session_request(Peer,#{<<"kind">> := <<"policy">>,<<"signer">> := Signer,<<"state">> := Packet},S) ->
    merge(Peer,#{<<"signer">> => Signer,<<"state">> => Packet},S).

%% Policy exchange. A statement is trusted when its signer holds `grant` in the
%% policy this Device already has, or when certificates lead from the creator
%% to the signer at a revision newer than this Device has seen.
merge(_,null,S) -> S;
merge(Peer,State,#{policy := Cur}=S) ->
    try
        ba_session_passport:exact(State,[<<"signer">>,<<"state">>]),
        Signer = maps:get(<<"signer">>,State),Packet = maps:get(<<"state">>,State),
        St = ba_session_passport:statement(Packet,Signer),P = maps:get(<<"policy">>,St),
        %% The signer needs grant before its change, not after: a grant holder
        %% may sign the policy in which it gives up its own grant.
        true = same_session(P,S),CurRev = maps:get(<<"revision">>,Cur),
        true = ba_session_privileges:has(grant,Signer,Cur) orelse
               ba_session_passport:grant_revision(Signer,maps:get(authority,S),St) > CurRev,
        case order(maps:get(<<"revision">>,P),Packet,S) of
            newer -> self_check(publish(checkpoint(adopt(Signer,Packet,St,S))));
            same -> S;
            older -> tell(Peer,S),S
        end
    catch exit:{membership_storage_failed,_} = Reason -> exit(Reason);
          _:_ -> S#{rejected := maps:get(rejected,S)+1} end.
%% Equal revisions with different content resolve to the smaller statement hash,
%% so Devices that saw concurrent changes still converge on one policy.
order(Rev,Packet,#{policy := Cur,signed := Mine}) ->
    CurRev = maps:get(<<"revision">>,Cur),
    if Rev > CurRev -> newer;
       Rev < CurRev -> older;
       Packet =:= Mine -> same;
       Mine =:= undefined -> newer;
       true -> case crypto:hash(sha256,Packet) < crypto:hash(sha256,Mine) of true -> newer;false -> older end
    end.
adopt(Signer,Packet,St,S) ->
    P = maps:get(<<"policy">>,St),Removed = maps:get(<<"removed">>,P),
    S#{policy := P,signed := Packet,signer := Signer,delegations := maps:get(<<"delegations">>,St),
       name := maps:get(<<"name">>,St),encountered := maps:get(encountered,S)--Removed,
       reachable := maps:map(fun(_,L) -> L--Removed end,maps:get(reachable,S))}.
tell(Peer,S) -> tell_all([Peer],S).
tell_all(Peers,S) ->
    case policy_state(S) of
        null -> ok;
        State -> ba_session_control:session_request(Peers,State#{<<"kind">> => <<"policy">>})
    end.
self_check(#{id := Id}=S) ->
    case lists:member(Id,removed(S)) of
        %% Stay visible as removed; control stops and nobody is contacted.
        true -> invalidate(),S#{state := revoked,until := 0};
        false -> S
    end.
%% A grant holder's change: next revision, certificates for its grant holders.
update(Change,#{policy := P0,id := Id,session := Session}=S) ->
    case Change(P0) of
        {ok,P1} ->
            Rev = maps:get(<<"revision">>,P0)+1,P = P1#{<<"revision">> := Rev},ok = ba_session_passport:policy(P),
            Creator = maps:get(authority,S),Old = maps:get(delegations,S),
            %% Certificates for every grant holder, and for this signer even when
            %% it gives up grant here, so a newcomer can still verify this change.
            Keep = maps:with([Id],Old),
            D = maps:merge(Keep,maps:from_list([{H,case maps:find(H,Old) of
                    {ok,Cert} -> Cert;
                    error -> sign(ba_session_passport:delegation(Session,Id,H,Rev),S)
                end} || H <- holders(P),H=/=Creator])),
            St = #{<<"name">> => maps:get(name,S),<<"policy">> => P,<<"delegations">> => D},
            Next = checkpoint(adopt(Id,sign(St,S),St,S)),
            %% Tell the Devices the change concerns (rights holders before and
            %% after, the removed) and the ones this Device deals with; it
            %% spreads further on contact.
            tell_all(lists:usort(maps:keys(maps:get(<<"members">>,P0))++maps:keys(maps:get(<<"members">>,P))++
                maps:get(<<"removed">>,P)++maps:get(encountered,S))--[Id],Next),
            {ok,self_check(publish(Next))};
        Error -> Error
    end.
member(Device,P,S) ->
    Members = maps:get(<<"members">>,P),
    case {maps:is_key(Device,Members),ba_hex:valid(Device,64),map_size(Members) < 16} of
        {true,_,_} -> {ok,P};
        {false,true,true} -> {ok,P#{<<"members">> := Members#{Device => #{<<"permissions">> => defaults()}},
                                    <<"removed">> := lists:delete(Device,removed(S))}};
        {false,false,_} -> {error,unknown_device};
        {false,true,false} -> {error,too_many_members}
    end.
reply({ok,Next},_) -> {reply,ok,Next};
reply(Error,S) -> {reply,Error,S}.

checkpoint(#{session := Session,link := Link,name := Name}=S) ->
    Saved = ba_device_store:load(saved_sessions,#{}),
    Record = case maps:get(signed,S) of
        undefined -> #{link => Link};
        Packet -> #{link => Link,signed => Packet,signer => maps:get(signer,S)}
    end,
    Kept = maps:from_list(lists:sublist(lists:reverse(lists:keysort(2,
        [{K,maps:get(at,V,0)} || {K,V} <- maps:to_list(maps:remove(Session,Saved))])),31)),
    ok = save(saved_sessions,(maps:with(maps:keys(Kept),Saved))#{Session => Record#{at => erlang:system_time(second)}}),
    ba_session:remember(self(),#{name => Name,session => Session,config => #{mode => join,invitation => Link}}),S.
save(Name,Data) ->
    try ba_device_store:save(Name,Data)
    catch _:_ -> exit({membership_storage_failed,Name}) end.

%% What the control layer checks each request against, and the Devices this
%% one can address (peers: neighbours and Devices it dealt with).
view(#{id := Id,policy := P}=S) ->
    Rights = fun(L) -> lists:usort([ba_session_passport:permission(X) || X <- L]) end,
    Members = maps:map(fun(_,#{<<"permissions">> := L}) -> Rights(L) end,maps:get(<<"members">>,P)),
    Privileges = maps:map(fun(D,_) -> permissions(D,P) end,maps:merge(maps:get(<<"members">>,P),maps:from_list([{D,x} || D <- [Id|contacts(S)]]))),
    #{device_privileges => Privileges,local_permissions => permissions(Id,P),
      policy => #{session => maps:get(session,S),authority => maps:get(authority,S),manager => maps:get(<<"manager">>,P),
          revision => maps:get(<<"revision">>,P)+1,invitation => maps:get(invitation,S),join => maps:get(join,S),
          members => maps:remove(Id,Members),defaults => Rights(defaults()),removed => removed(S),
          peers => maps:from_list([{D,Rights(permissions(D,P))} || D <- contacts(S)])},
      envelope => maps:get(envelope,S),reachable => reachable(S),routes => #{},until => infinity}.
permissions(Id,#{<<"members">> := Members}) ->
    case maps:find(Id,Members) of {ok,#{<<"permissions">> := Perms}} -> Perms;error -> defaults() end.
%% What a Session member may ask of another without a privilege.
defaults() -> [<<"capabilities_read">>,<<"status_read">>,<<"stream_read">>,<<"stream_subscribe">>,<<"time_read">>].
publish(#{state := authorized}=S) ->
    ba_contacts:observe(maps:get(session,S),maps:get(name,S),maps:get(encountered,S)),
    View = chat_view(S),
    notify({membership_authorized,View}),S;
publish(S) -> S.
chat_view(S) ->
    chat({participants,reachable(S)}),
    View = view(S),chat({session_privileges,maps:get(device_privileges,View)}),View.
resend_chat() -> gen_server:cast(ba_session_scope:ref(?MODULE),resend_chat).
notify_audio(Event) -> case ba_session_scope:whereis(ba_audio_receiver) of undefined -> ok;Pid -> Pid ! Event,ok end.
chat(Event) -> case ba_session_scope:whereis(ba_session_chat) of undefined -> ok;Chat -> Chat ! Event,ok end.
invalidate() -> notify(membership_invalidated).
notify(Event) -> case ba_session_scope:whereis(ba_session_control) of undefined -> ok;Pid -> Pid ! Event end.
sign(B,S) -> ba_session_passport:sign(B,maps:get(private,S)).
policy_state(#{signed := undefined}) -> null;
policy_state(#{signed := Packet,signer := Signer}) -> #{<<"signer">> => Signer,<<"state">> => Packet}.
same_session(P,S) ->
    maps:get(<<"session">>,P)=:=maps:get(session,S) andalso maps:get(<<"authority">>,P)=:=maps:get(authority,S).
removed(#{policy := P}) -> maps:get(<<"removed">>,P).
%% Dark Sessions: the Devices shown are this one and the ones it has bumped
%% into. There is no Manager; nobody knows the rest.
known(#{id := Id}=S) -> [Id|lists:delete(Id,maps:get(encountered,S))].
reachable(#{reachable := R}) -> lists:usort(lists:append(maps:values(R))).
contacts(#{id := Id}=S) -> lists:delete(Id,lists:usort(maps:get(encountered,S)++reachable(S))).
grant_holder(#{id := Id,policy := P,state := authorized}) -> ba_session_privileges:has(grant,Id,P);
grant_holder(_) -> false.
grant_holder_present(#{policy := P,id := Self}=S) ->
    lists:any(fun(Id) -> Id=:=Self orelse lists:member(Id,reachable(S)) end,holders(P)).
fresh(N) -> binary:encode_hex(crypto:strong_rand_bytes(N)).
now_ms() -> erlang:monotonic_time(millisecond).
format_status(Status) -> maps:map(fun(state,S) -> maps:with([id,session,state],S);(log,_) -> [];(_,_) -> redacted end,Status).

holders(P) -> ba_session_privileges:holders(grant,P).
local_privileges(#{policy := P,id := Id}) -> ba_session_privileges:names(permissions(Id,P)).
%% Open requests for a Device and privilege, judged before any change.
open_refs(Device,Wire,#{policy := P}=S) -> ba_session_board:open_ids(maps:get(board,S),P,Device,Wire).
%% Answers requests with signed entries (decline or granted) and gossips them.
answer(How,Device,Wire,Refs,#{id := Id}=S) ->
    Entries = [ba_session_board:How(maps:get(session,S),Id,Ref,Device,Wire,maps:get(private,S)) || Ref <- Refs],
    lists:foldl(fun(E,Acc) -> {_,Next} = post(E,Acc),Next end,S,Entries).
%% Open requests from this Device's copy of the board.
open_requests(#{policy := P}=S) ->
    maps:map(fun(_,Wires) -> ba_session_privileges:names(Wires) end,ba_session_board:open(maps:get(board,S),P)).
board_context(#{policy := P}=S) -> #{session => maps:get(session,S),invitation => maps:get(invitation,S),policy => P}.
%% Adds this Device's own entry and gossips it to its neighbours.
post({Id,Packet},S) ->
    {_,Board} = ba_session_board:merge(#{Id => Packet},board_context(S),maps:get(board,S)),
    Next = S#{board := Board},
    case contacts(Next) of
        [] -> {{error,grant_holder_unavailable},Next};
        Peers -> [send_board(D,#{Id => Packet}) || D <- Peers],{ok,Next}
    end.
send_board(_,Entries) when map_size(Entries)=:=0 -> ok;
%% A few entries per message keep each sealed message within Reception's size.
send_board(Peer,Entries) ->
    {Now,Rest} = lists:split(min(6,map_size(Entries)),maps:to_list(Entries)),
    ba_session_control:session_request([Peer],#{<<"kind">> => <<"board">>,<<"entries">> => maps:from_list(Now)}),
    send_board(Peer,maps:from_list(Rest)).
%% A newly learned entry. Everyone sees a request in chat; a grant holder
%% decides it by its own answer for such requests: Always grants, No declines
%% (a signed entry, so other copies close too), Ask leaves it open.
learned(#{<<"kind">> := <<"request">>,<<"id">> := Ref,<<"device">> := Device,<<"privilege">> := Wire},#{id := Id}=S) ->
    chat({privilege_requested,Device,Wire}),
    case grant_holder(S) of
        false -> S;
        true ->
            Answer = case Wire=:=ba_session_privileges:wire(on_air) of true -> on_air_requests;false -> moderator_requests end,
            case ba_device_request:approve(Answer,Device) of
                ok -> {reply,_,Next} = handle_call({change,grant,Device,Wire},undefined,S),Next;
                {error,waiting_for_approval} -> S;
                {error,_} ->
                    {_,Next} = post(ba_session_board:decline(maps:get(session,S),Id,Ref,Device,Wire,maps:get(private,S)),S),Next
            end
    end;
learned(_,S) -> S.
%% Signed per request; each present grant holder decides it. ok is local
%% acceptance, not remote receipt.
ask_holders(Payload,#{policy := P}=S) ->
    case [Id || Id <- holders(P),lists:member(Id,contacts(S))] of
        [] -> {error,grant_holder_unavailable};
        Holders -> ba_session_control:session_request(Holders,Payload)
    end.
valid_name(Name) -> is_binary(Name) andalso byte_size(Name)>0 andalso byte_size(Name)=<128 andalso is_list(unicode:characters_to_list(Name)).
