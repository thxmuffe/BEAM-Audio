%% Participation, privileges and connections are separate. Holding the link lets
%% a Device participate; each pair of present Devices proves the link to each
%% other independently, with no hub. Privileges are a signed, versioned policy
%% that grant holders change and every Device keeps; the highest revision wins.
-module(ba_buffee_membership).
-behaviour(gen_server).
-export([start_link/0,status/0,current/0,invite/1,invite_devices/2,depart/0,grant/2,revoke/1,grant_privilege/2,take_privilege/2,decline_privilege/2,request_privilege/1,end_session/0,rename/1]).
-export([init/1,handle_call/3,handle_cast/2,handle_info/2,format_status/1]).
-ifdef(TEST).
-export([order/3]).
-endif.
-define(LOOKUP_MS,2000).
-define(HANDSHAKE_MS,10000).
-define(REFUSED_MS,30000).
-define(MAX_PARTICIPANTS,15).
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
depart() -> gen_server:call(ba_session_scope:ref(?MODULE),depart).
invite_devices(Ids,TTL) -> gen_server:call(ba_session_scope:ref(?MODULE),{invite_devices,Ids,TTL}).
grant(Device,Permissions) -> gen_server:call(ba_session_scope:ref(?MODULE),{grant,Device,Permissions}).
revoke(Device) -> gen_server:call(ba_session_scope:ref(?MODULE),{revoke,Device}).

init([]) ->
    {Pub,Private} = ba_device_store:identity(),Id = binary:encode_hex(Pub),
    {ok,Config} = ba_session_scope:get_env(buffee_membership),
    S = boot(Config,#{id => Id,private => Private,rejected => 0}),
    erlang:send_after(250,self(),tick),{ok,S}.
%% Creating writes the permanent link; the creator then participates like anyone.
boot(#{mode := create,name := Name,desks := URLs} = Config,#{id := Id} = S) ->
    ok = ba_buffee_passport:urls(URLs),true = valid_name(Name),
    Nonce = maps:get(nonce,Config,fresh(16)),Buffee = ba_buffee_passport:session_id(Id,Nonce),
    case maps:find(buffee,Config) of {ok,Wanted} -> Buffee = Wanted;error -> ok end,
    I = #{<<"v">> => 1,<<"type">> => <<"invitation">>,<<"buffee">> => Buffee,<<"authority">> => Id,
          <<"nonce">> => Nonce,<<"secret">> => fresh(16),<<"desks">> => URLs,<<"name">> => Name},
    Started = start(ba_buffee_passport:link(I),I,maps:get(desk,Config,hd(URLs)),S),
    %% The link carries no name: sign the starting policy so joiners learn it.
    case maps:get(signed,Started) of
        undefined -> {ok,Signed} = update(fun(P) -> {ok,P} end,Started),Signed;
        _ -> Started
    end;
boot(#{mode := join,invitation := Link} = Config,S) ->
    {_,I} = ba_buffee_passport:parse_invitation(Link),
    start(Link,I,maps:get(desk,Config,hd(maps:get(<<"desks">>,I))),S);
boot(#{mode := resume},_S) ->
    error(ephemeral_buffees_cannot_be_resumed).
start(Link,I,Primary,S) ->
    Buffee = maps:get(<<"buffee">>,I),URLs = maps:get(<<"desks">>,I),true = lists:member(Primary,URLs),
    Secret = maps:get(<<"secret">>,I),
    Base = S#{link => Link,buffee => Buffee,authority => maps:get(<<"authority">>,I),secret => Secret,
        cap => ba_buffee_passport:mailbox(Secret),name => maps:get(<<"name">>,I),urls => URLs,primary => Primary,
        policy => ba_buffee_passport:genesis(I,ba_settings:app(buffee_default_permissions,[<<"capabilities_read">>,<<"job_offer">>,<<"status_read">>])),signed => undefined,signer => undefined,delegations => #{},
        participants => #{},pairs => #{},missing => #{},pending => #{},outgoing => #{},requests => #{},
        state => authorized,until => infinity,last_lookup => now_ms()-?LOOKUP_MS},
    Ready = restore(maps:get(Buffee,ba_device_store:load(buffee_sessions,#{}),undefined),Base),
    ok = ba_buffee_desks:configure(Buffee,URLs,Primary,#{}),
    ok = ba_buffee_desks:advertise(maps:get(cap,Ready)),
    checkpoint(Ready),self_check(publish(Ready)).
%% This Device's own record: the policy it last accepted.
restore(#{signer := Signer,signed := Packet},S) ->
    try St = ba_buffee_passport:statement(Packet,Signer),
        true = same_session(maps:get(<<"policy">>,St),S),adopt(Signer,Packet,St,S)
    catch _:_ -> S end;
restore(_,S) -> S.

handle_call(status,_,#{policy := P}=S) ->
    {reply,#{id => maps:get(id,S),buffee => maps:get(buffee,S),privileges => local_privileges(S),grant_holders => holders(P),
        name => maps:get(name,S),owner => maps:get(authority,S),requests => open_requests(S),
        state => maps:get(state,S),grant_holder_present => grant_holder_present(S),epoch => null,
        revision => maps:get(<<"revision">>,P),members => known(S),participants => maps:keys(maps:get(participants,S)),
        membership => null,rejected => maps:get(rejected,S)},S};
handle_call(current,_,#{state := authorized} = S) -> {reply,{ok,view(S)},S};
handle_call(current,_,S) -> {reply,{error,maps:get(state,S)},S};
%% Every participant holds the same permanent link and may share it.
handle_call({invite,_},_,S) -> {reply,{ok,maps:get(link,S)},S};
handle_call({invite_devices,Ids,_},_,S) when is_list(Ids),length(Ids)>0,length(Ids)=<15 ->
    case lists:all(fun(Id) -> Id=:=undefined orelse hex(Id,64) end,Ids) of
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
            maps:foreach(fun(Peer,R) ->
                send(Peer,R,<<"ended">>,fresh(16),#{<<"pair">> => hd(maps:get(Peer,maps:get(pairs,S)))},S)
            end,maps:get(participants,S)),{reply,ok,S}
    end;
handle_call(end_session,_,S) -> {reply,{error,end_privilege_required},S};
%% Leaving changes no signed state: Reception drops this Device's advertisement.
handle_call(depart,_,S) -> {reply,ok,S};
handle_call({rename,Name},_,#{state := authorized,policy := P,id := Id}=S) ->
    case {valid_name(Name),grant_holder(S),ba_session_privileges:has(on_air,Id,P)} of
        {false,_,_} -> {reply,{error,invalid_session_name},S};
        {true,true,_} -> reply(update(fun(Q) -> {ok,Q} end,S#{name := Name}),S);
        {true,false,true} -> {reply,ask_holders(<<"rename_request">>,#{<<"name">> => Name},S),S};
        {true,false,false} -> {reply,{error,forbidden},S}
    end;
%% Every privilege is requested. A grant holder's own request needs no one else.
handle_call({request_privilege,Wire},From,#{id := Id}=S) ->
    case grant_holder(S) of
        true -> handle_call({change,grant,Id,Wire},From,S);
        false ->
            Result = ask_holders(<<"privilege_request">>,#{<<"privilege">> => Wire},S),
            case Result of ok -> chat({privilege_requested,Id,Wire});_ -> ok end,
            {reply,Result,S}
    end;
%% Declining only clears this Device's reminder; the requester is not told.
handle_call({decline,Device,Wire},_,S) ->
    case grant_holder(S) of
        true -> Requests = maps:get(requests,S),
            {reply,ok,S#{requests := Requests#{Device => lists:delete(Wire,maps:get(Device,Requests,[]))}}};
        false -> {reply,{error,grant_required},S}
    end;
handle_call({change,Op,Device,Wire},_,#{id := Id}=S) ->
    case grant_holder(S) of
        true ->
            case update(fun(P) -> case member(Device,P,S) of
                    {ok,Q} -> ba_session_privileges:change(Id,Device,Op,Wire,Q);
                    Error -> Error
                end end,S) of
                {ok,Next} -> Requests = maps:get(requests,Next),
                    {reply,ok,Next#{requests := Requests#{Device => lists:delete(Wire,maps:get(Device,Requests,[]))}}};
                Error -> {reply,Error,S}
            end;
        %% Any Device may give up its own privilege; a grant holder applies it.
        false when Op=:=take,Device=:=Id -> {reply,ask_holders(<<"privilege_release">>,#{<<"privilege">> => Wire},S),S};
        false -> {reply,{error,grant_required},S}
    end;
handle_call({grant,Device,Permissions},_,S) ->
    Result = try
        true = grant_holder(S),ok = ba_buffee_passport:permissions(Permissions),
        update(fun(P) -> {ok,Q} = member(Device,P,S),Members = maps:get(<<"members">>,Q),
            {ok,Q#{<<"members">> := Members#{Device := #{<<"permissions">> => Permissions}}}} end,S)
    catch exit:{membership_storage_failed,_} = Reason -> exit(Reason);
          _:_ -> {error,invalid_grant} end,
    case Result of {ok,Next} -> {reply,ok,Next};_ -> {reply,{error,invalid_grant},S} end;
handle_call({revoke,Device},_,#{id := Id}=S) ->
    case grant_holder(S) andalso Device=/=Id andalso hex(Device,64) of
        false -> {reply,{error,invalid_revocation},S};
        true -> reply(update(fun(P) ->
            Manager = case maps:get(<<"manager">>,P) of Device -> maps:get(<<"authority">>,P);M -> M end,
            Removed = lists:usort([Device|maps:get(<<"removed">>,P)]),
            case length(Removed) =< 31 of
                true -> {ok,P#{<<"manager">> := Manager,<<"members">> := maps:remove(Device,maps:get(<<"members">>,P)),
                               <<"removed">> := Removed}};
                false -> {error,too_many_removed}
            end end,S),S)
    end;
handle_call(_,_,S) -> {reply,{error,unsupported},S}.
handle_cast(_,S) -> {noreply,S}.

handle_info(tick,S0) ->
    Now = now_ms(),
    S1 = S0#{pending := maps:filter(fun(_,E) -> maps:get(deadline,E) > Now end,maps:get(pending,S0)),
             outgoing := maps:filter(fun(_,E) -> maps:get(deadline,E) > Now end,maps:get(outgoing,S0))},
    S2 = case Now-maps:get(last_lookup,S1) >= ?LOOKUP_MS of true -> discover(S1);false -> S1 end,
    erlang:send_after(250,self(),tick),{noreply,S2};
handle_info({desk_event,_,connected},S) ->
    %% Do not wait for the next lookup after a Desk becomes usable.
    {noreply,discover(S)};
handle_info({desk_event,_,_},S) -> {noreply,S};
handle_info({lookup,URL,{ok,Owners}},S) when is_list(Owners) ->
    {noreply,lists:foldl(fun(Owner,Acc) -> hello(Owner,URL,Acc) end,absent(Owners,S),Owners)};
handle_info({lookup,_,_},S) -> {noreply,S};
handle_info({desk_delivery,_,From,Packet},S) ->
    try
        B = ba_buffee_passport:verify(Packet,From),
        ba_buffee_passport:exact(B,[<<"v">>,<<"type">>,<<"from">>,<<"to">>,<<"buffee">>,<<"request">>,<<"payload">>]),
        #{<<"v">> := 1,<<"from">> := From,<<"to">> := To,<<"buffee">> := Buffee,<<"request">> := Req} = B,
        To = maps:get(id,S),Buffee = maps:get(buffee,S),true = hex(Req,32),
        {noreply,incoming(From,B,S)}
    catch exit:{membership_storage_failed,_} = Reason -> exit(Reason);
          _:_ -> {noreply,S#{rejected := maps:get(rejected,S)+1}} end;
handle_info(_,S) -> {noreply,S}.

%% Reception lists every Device present on the Session mailbox. Lookups run
%% outside this process so a slow Desk never blocks membership.
discover(#{state := authorized,urls := URLs,cap := Cap}=S) ->
    Self = self(),
    [ba_session_scope:spawn(fun() ->
        Self ! {lookup,URL,try ba_buffee_desks:lookup(URL,Cap) catch _:_ -> {error,unavailable} end}
    end) || URL <- URLs],
    S#{last_lookup := now_ms()};
discover(S) -> S#{last_lookup := now_ms()}.
hello(Owner,URL,#{id := Id,participants := Ps,outgoing := Out}=S) ->
    case Owner=:=Id orelse maps:is_key(Owner,Ps) orelse maps:is_key(Owner,Out)
         orelse lists:member(Owner,removed(S)) orelse not hex(Owner,64) of
        true -> S;
        false ->
            Req = fresh(16),Nonce = fresh(32),R = #{<<"desk">> => URL,<<"mailbox">> => maps:get(cap,S)},
            send(Owner,R,<<"hello">>,Req,#{<<"nonce">> => Nonce,<<"route">> => ba_buffee_desks:route()},S),
            S#{outgoing := Out#{Owner => #{request => Req,nonce => Nonce,deadline => now_ms()+?HANDSHAKE_MS}}}
    end.

%% Pairwise handshake. Each side proves the link's secret, bound to both IDs.
incoming(Peer,#{<<"type">> := <<"hello">>,<<"request">> := Req,<<"payload">> := Data},#{pending := Pending}=S)
        when map_size(Pending) < 16 ->
    ba_buffee_passport:exact(Data,[<<"nonce">>,<<"route">>]),
    Nonce = maps:get(<<"nonce">>,Data),true = hex(Nonce,64),
    R = maps:get(<<"route">>,Data),ok = ba_buffee_passport:route(R,maps:get(urls,S)),
    case lists:member(Peer,removed(S)) of
        true -> send(Peer,R,<<"denied">>,Req,#{<<"nonce">> => Nonce,<<"policy">> => policy_state(S)},S),S;
        false ->
            Challenge = fresh(32),
            send(Peer,R,<<"challenge">>,Req,#{<<"nonce">> => Nonce,<<"challenge">> => Challenge,
                <<"proof">> => proof(S,[<<"responder">>,Nonce,maps:get(id,S),Peer]),
                <<"route">> => ba_buffee_desks:route()},S),
            S#{pending := Pending#{Req => #{peer => Peer,route => R,nonce => Nonce,challenge => Challenge,
                deadline => now_ms()+?HANDSHAKE_MS}}}
    end;
incoming(Peer,#{<<"type">> := <<"challenge">>,<<"request">> := Req,<<"payload">> := Data},#{outgoing := Out}=S) ->
    #{request := Req,nonce := Nonce} = E = maps:get(Peer,Out),false = maps:is_key(refused,E),
    ba_buffee_passport:exact(Data,[<<"nonce">>,<<"challenge">>,<<"proof">>,<<"route">>]),
    Nonce = maps:get(<<"nonce">>,Data),Challenge = maps:get(<<"challenge">>,Data),true = hex(Challenge,64),
    true = equal(proof(S,[<<"responder">>,Nonce,Peer,maps:get(id,S)]),maps:get(<<"proof">>,Data)),
    R = maps:get(<<"route">>,Data),ok = ba_buffee_passport:route(R,maps:get(urls,S)),
    send(Peer,R,<<"proof">>,Req,#{<<"challenge">> => Challenge,
        <<"proof">> => proof(S,[<<"joiner">>,Challenge,maps:get(id,S),Peer]),<<"policy">> => policy_state(S)},S),
    S#{outgoing := Out#{Peer := E#{challenge => Challenge,route => R}}};
incoming(Peer,#{<<"type">> := <<"proof">>,<<"request">> := Req,<<"payload">> := Data},#{pending := Pending}=S) ->
    #{peer := Peer,route := R,nonce := Nonce,challenge := Challenge} = maps:get(Req,Pending),
    ba_buffee_passport:exact(Data,[<<"challenge">>,<<"proof">>,<<"policy">>]),
    Challenge = maps:get(<<"challenge">>,Data),
    true = equal(proof(S,[<<"joiner">>,Challenge,Peer,maps:get(id,S)]),maps:get(<<"proof">>,Data)),
    S1 = merge(Peer,maps:get(<<"policy">>,Data),S#{pending := maps:remove(Req,Pending)}),
    Full = map_size(maps:get(participants,S1)) >= ?MAX_PARTICIPANTS andalso not maps:is_key(Peer,maps:get(participants,S1)),
    case lists:member(Peer,removed(S1)) orelse Full orelse maps:get(state,S1)=/=authorized of
        true -> send(Peer,R,<<"denied">>,Req,#{<<"nonce">> => Nonce,<<"policy">> => policy_state(S1)},S1),S1;
        false ->
            S2 = join(Peer,R,pair(Nonce,Challenge),S1),
            send(Peer,R,<<"welcome">>,Req,#{<<"policy">> => policy_state(S2)},S2),S2
    end;
incoming(Peer,#{<<"type">> := <<"welcome">>,<<"request">> := Req,<<"payload">> := Data},#{outgoing := Out}=S) ->
    #{request := Req,nonce := Nonce,challenge := Challenge,route := R} = maps:get(Peer,Out),
    ba_buffee_passport:exact(Data,[<<"policy">>]),
    Theirs = maps:get(<<"policy">>,Data),
    S1 = merge(Peer,Theirs,S#{outgoing := maps:remove(Peer,Out)}),
    case lists:member(Peer,removed(S1)) orelse maps:get(state,S1)=/=authorized of
        true -> S1;
        false ->
            S2 = join(Peer,R,pair(Nonce,Challenge),S1),
            %% The responder sent an older policy than ours: bring it up to date.
            case policy_state(S2)=:=Theirs of true -> ok;false -> tell(Peer,S2) end,S2
    end;
incoming(Peer,#{<<"type">> := <<"denied">>,<<"request">> := Req,<<"payload">> := Data},#{outgoing := Out}=S) ->
    #{request := Req,nonce := Nonce} = E = maps:get(Peer,Out),
    ba_buffee_passport:exact(Data,[<<"nonce">>,<<"policy">>]),Nonce = maps:get(<<"nonce">>,Data),
    %% A refusal proves nothing by itself; only its signed policy can remove us.
    merge(Peer,maps:get(<<"policy">>,Data),S#{outgoing := Out#{Peer := E#{refused => true,deadline := now_ms()+?REFUSED_MS}}});
%% Everything below comes only from Devices that completed the handshake.
incoming(Peer,#{<<"type">> := Type,<<"payload">> := Data},#{participants := Ps}=S) when is_map_key(Peer,Ps) ->
    participant(Peer,Type,Data,S);
incoming(_,_,_) -> error(unexpected_membership_message).

participant(Peer,<<"offline">>,Data,#{participants := Ps}=S) ->
    ba_buffee_passport:exact(Data,[<<"route">>]),R = maps:get(<<"route">>,Data),R = maps:get(Peer,Ps),
    publish(routes(S#{participants := maps:remove(Peer,Ps),pairs := maps:remove(Peer,maps:get(pairs,S))}));
participant(Peer,<<"policy">>,Data,S) ->
    ba_buffee_passport:exact(Data,[<<"policy">>]),merge(Peer,maps:get(<<"policy">>,Data),S);
participant(Peer,<<"rename_request">>,Data,#{policy := P}=S) ->
    ba_buffee_passport:exact(Data,[<<"name">>]),true = grant_holder(S),true = ba_session_privileges:has(on_air,Peer,P),
    {reply,_,Next} = handle_call({rename,maps:get(<<"name">>,Data)},undefined,S),Next;
participant(Peer,<<"privilege_release">>,Data,S) ->
    true = grant_holder(S),
    {reply,_,Next} = handle_call({change,take,Peer,requested(Data)},undefined,S),Next;
participant(Peer,<<"privilege_request">>,Data,S) ->
    true = grant_holder(S),Wire = requested(Data),Requests = maps:get(requests,S),
    Answer = answer(Wire),
    case Answer of no -> ok;_ -> chat({privilege_requested,Peer,Wire}) end,
    case Answer of
        always -> {reply,_,Next} = handle_call({change,grant,Peer,Wire},undefined,S),Next;
        no -> S;
        ask -> S#{requests := Requests#{Peer => lists:usort([Wire|maps:get(Peer,Requests,[])])}}
    end;
participant(Peer,<<"ended">>,Data,#{policy := P,pairs := Pairs}=S) ->
    true = ba_session_privileges:has(end_session,Peer,P),
    ba_buffee_passport:exact(Data,[<<"pair">>]),true = lists:member(maps:get(<<"pair">>,Data),maps:get(Peer,Pairs)),
    invalidate(),ba_buffee:ended(self()),S#{state := ended,until := 0};
participant(_,_,_,_) -> error(unexpected_membership_message).

%% Both Devices may start a handshake at once; each side records every pair it
%% completed, so End is accepted whichever handshake the sender remembers.
join(Peer,R,Pair,#{participants := Ps,pairs := Pairs}=S) ->
    Recent = lists:sublist([Pair|maps:get(Peer,Pairs,[])],4),
    publish(routes(S#{participants := Ps#{Peer => R},pairs := Pairs#{Peer => Recent},
                      missing := maps:remove(Peer,maps:get(missing,S))})).
%% A Device that vanished without saying so (crash, power loss) stops being a
%% participant once a successful lookup misses it twice in a row.
absent(Owners,#{participants := Ps,missing := Missing}=S) ->
    {Gone,Counts} = maps:fold(fun(Peer,_,{G,C}) ->
        case lists:member(Peer,Owners) of
            true -> {G,C};
            false -> N = maps:get(Peer,Missing,0)+1,
                case N >= 2 of true -> {[Peer|G],C};false -> {G,C#{Peer => N}} end
        end end,{[],#{}},Ps),
    Next = S#{missing := Counts},
    case Gone of
        [] -> Next;
        _ -> publish(routes(Next#{participants := maps:without(Gone,Ps),pairs := maps:without(Gone,maps:get(pairs,S))}))
    end.
routes(S) ->
    ok = ba_buffee_desks:configure(maps:get(buffee,S),maps:get(urls,S),maps:get(primary,S),maps:get(participants,S)),S.

%% Policy exchange. A statement is trusted when its signer holds `grant` in the
%% policy this Device already has, or when certificates lead from the creator
%% to the signer at a revision newer than this Device has seen.
merge(_,null,S) -> S;
merge(Peer,State,#{policy := Cur}=S) ->
    try
        ba_buffee_passport:exact(State,[<<"signer">>,<<"state">>]),
        Signer = maps:get(<<"signer">>,State),Packet = maps:get(<<"state">>,State),
        St = ba_buffee_passport:statement(Packet,Signer),P = maps:get(<<"policy">>,St),
        %% The signer needs grant before its change, not after: a grant holder
        %% may sign the policy in which it gives up its own grant.
        true = same_session(P,S),CurRev = maps:get(<<"revision">>,Cur),
        true = ba_session_privileges:has(grant,Signer,Cur) orelse
               ba_buffee_passport:grant_revision(Signer,maps:get(authority,S),St) > CurRev,
        case order(maps:get(<<"revision">>,P),Packet,S) of
            newer -> self_check(publish(routes(checkpoint(adopt(Signer,Packet,St,S)))));
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
adopt(Signer,Packet,St,#{participants := Ps}=S) ->
    P = maps:get(<<"policy">>,St),Removed = maps:get(<<"removed">>,P),
    S#{policy := P,signed := Packet,signer := Signer,delegations := maps:get(<<"delegations">>,St),
       name := maps:get(<<"name">>,St),participants := maps:without(Removed,Ps),
       pairs := maps:without(Removed,maps:get(pairs,S))}.
tell(Peer,#{participants := Ps}=S) ->
    case maps:find(Peer,Ps) of
        {ok,R} -> send(Peer,R,<<"policy">>,fresh(16),#{<<"policy">> => policy_state(S)},S);
        error -> ok
    end.
self_check(#{id := Id}=S) ->
    case lists:member(Id,removed(S)) of
        %% Stay visible as removed; control stops and nobody is contacted.
        true -> invalidate(),S#{state := revoked,until := 0};
        false -> S
    end.
%% A grant holder's change: next revision, certificates for its grant holders.
update(Change,#{policy := P0,id := Id,buffee := Buffee}=S) ->
    case Change(P0) of
        {ok,P1} ->
            Rev = maps:get(<<"revision">>,P0)+1,P = P1#{<<"revision">> := Rev},ok = ba_buffee_passport:policy(P),
            Creator = maps:get(authority,S),Old = maps:get(delegations,S),
            %% Certificates for every grant holder, and for this signer even when
            %% it gives up grant here, so a newcomer can still verify this change.
            Keep = maps:with([Id],Old),
            D = maps:merge(Keep,maps:from_list([{H,case maps:find(H,Old) of
                    {ok,Cert} -> Cert;
                    error -> sign(ba_buffee_passport:delegation(Buffee,Id,H,Rev),S)
                end} || H <- holders(P),H=/=Creator])),
            St = #{<<"name">> => maps:get(name,S),<<"policy">> => P,<<"delegations">> => D},
            Next = routes(checkpoint(adopt(Id,sign(St,S),St,S))),
            %% Tell everyone present before the change, so a removed Device learns it.
            maps:foreach(fun(Peer,_) -> tell(Peer,Next#{participants := maps:get(participants,S)}) end,
                maps:get(participants,S)),
            {ok,self_check(publish(Next))};
        Error -> Error
    end.
member(Device,P,S) ->
    Members = maps:get(<<"members">>,P),
    case {maps:is_key(Device,Members),hex(Device,64),map_size(Members) < 16} of
        {true,_,_} -> {ok,P};
        {false,true,true} -> {ok,P#{<<"members">> := Members#{Device => #{<<"permissions">> => defaults()}},
                                    <<"removed">> := lists:delete(Device,removed(S))}};
        {false,false,_} -> {error,unknown_device};
        {false,true,false} -> {error,too_many_members}
    end.
reply({ok,Next},_) -> {reply,ok,Next};
reply(Error,S) -> {reply,Error,S}.

checkpoint(#{buffee := Buffee,link := Link,name := Name}=S) ->
    Saved = ba_device_store:load(buffee_sessions,#{}),
    Record = case maps:get(signed,S) of
        undefined -> #{link => Link};
        Packet -> #{link => Link,signed => Packet,signer => maps:get(signer,S)}
    end,
    Kept = maps:from_list(lists:sublist(lists:reverse(lists:keysort(2,
        [{K,maps:get(at,V,0)} || {K,V} <- maps:to_list(maps:remove(Buffee,Saved))])),31)),
    ok = save(buffee_sessions,(maps:with(maps:keys(Kept),Saved))#{Buffee => Record#{at => erlang:system_time(second)}}),
    ba_buffee:remember(self(),#{name => Name,buffee => Buffee,config => #{mode => join,invitation => Link}}),S.
save(Name,Data) ->
    try ba_device_store:save(Name,Data)
    catch _:_ -> exit({membership_storage_failed,Name}) end.

%% Present participants and their effective permissions for the control layer.
view(#{id := Id,policy := P}=S) ->
    Present = maps:put(Id,self,maps:get(participants,S)),
    Privileges = maps:map(fun(D,_) -> permissions(D,P) end,maps:merge(maps:get(<<"members">>,P),Present)),
    #{device_privileges => Privileges,local_permissions => permissions(Id,P),
      policy => ba_buffee_passport:runtime_policy(P,Id,maps:with(maps:keys(Present),Privileges)),
      routes => maps:get(participants,S),until => infinity}.
permissions(Id,#{<<"members">> := Members}) ->
    case maps:find(Id,Members) of {ok,#{<<"permissions">> := Perms}} -> Perms;error -> defaults() end.
%% Participants without a policy entry; the creator's own defaults are wider.
defaults() -> ba_settings:app(buffee_default_permissions,[]).
publish(#{state := authorized}=S) ->
    ba_contacts:observe(maps:get(buffee,S),maps:get(name,S),maps:keys(maps:get(participants,S))),
    chat({participants,lists:sort(maps:keys(maps:get(participants,S)))}),
    View = view(S),chat({session_privileges,maps:get(device_privileges,View)}),
    notify({membership_authorized,View}),S;
publish(S) -> S.
chat(Event) -> case ba_session_scope:whereis(ba_buffee_chat) of undefined -> ok;Chat -> Chat ! Event,ok end.
invalidate() -> notify(membership_invalidated).
notify(Event) -> case ba_session_scope:whereis(ba_buffee_control) of undefined -> ok;Pid -> Pid ! Event end.
send(To,R,Type,Request,Payload,S) ->
    Body = #{<<"v">> => 1,<<"type">> => Type,<<"from">> => maps:get(id,S),<<"to">> => To,
             <<"buffee">> => maps:get(buffee,S),<<"request">> => Request,<<"payload">> => Payload},
    ba_buffee_desks:send_route(To,R,<<"membership">>,sign(Body,S)).
sign(B,S) -> ba_buffee_passport:sign(B,maps:get(private,S)).
proof(#{secret := Secret},Parts) -> ba_buffee_passport:proof(Secret,Parts).
equal(A,B) when is_binary(A),is_binary(B),byte_size(A)=:=byte_size(B) -> crypto:hash_equals(A,B);
equal(_,_) -> false.
pair(Nonce,Challenge) -> binary:part(binary:encode_hex(crypto:hash(sha256,[Nonce,Challenge])),0,32).
policy_state(#{signed := undefined}) -> null;
policy_state(#{signed := Packet,signer := Signer}) -> #{<<"signer">> => Signer,<<"state">> => Packet}.
same_session(P,S) ->
    maps:get(<<"buffee">>,P)=:=maps:get(buffee,S) andalso maps:get(<<"authority">>,P)=:=maps:get(authority,S).
removed(#{policy := P}) -> maps:get(<<"removed">>,P).
known(#{id := Id,policy := P,participants := Ps}) ->
    lists:usort([Id|maps:keys(Ps)++maps:keys(maps:get(<<"members">>,P))]).
grant_holder(#{id := Id,policy := P,state := authorized}) -> ba_session_privileges:has(grant,Id,P);
grant_holder(_) -> false.
grant_holder_present(#{policy := P,id := Self,participants := Ps}) ->
    lists:any(fun(Id) -> Id=:=Self orelse (maps:is_key(Id,Ps) andalso
        (try ba_buffee_desks:peer_online(Id) catch exit:_ -> false end)) end,holders(P)).
fresh(N) -> binary:encode_hex(crypto:strong_rand_bytes(N)).
hex(B,N) -> ba_buffee_job:hex(B,N).
now_ms() -> erlang:monotonic_time(millisecond).
format_status(Status) -> maps:map(fun(state,S) -> maps:with([id,buffee,state],S);(log,_) -> [];(_,_) -> redacted end,Status).

holders(P) -> ba_session_privileges:holders(grant,P).
local_privileges(#{policy := P,id := Id}) -> ba_session_privileges:names(permissions(Id,P)).
%% Requests are a grant holder's local reminder, not signed Session state.
open_requests(#{policy := P}=S) ->
    maps:filtermap(fun(Device,Wires) ->
        case Wires--permissions(Device,P) of [] -> false;Open -> {true,ba_session_privileges:names(Open)} end
    end,maps:get(requests,S)).
%% This Device's user decides how requests for rights are answered: the on-air
%% right, and moderator rights (giving rights, ending the Session).
answer(Wire) ->
    Key=case Wire=:=ba_session_privileges:wire(on_air) of true -> on_air_requests;false -> moderator_requests end,
    try ba_device_config:policy(Key) catch exit:_ -> ask end.
requested(Data) ->
    ba_buffee_passport:exact(Data,[<<"privilege">>]),Wire=maps:get(<<"privilege">>,Data),
    ok=ba_buffee_passport:permissions([Wire]),Wire.
ask_holders(Type,Payload,#{policy := P,participants := Ps}=S) ->
    Results=[send(Id,R,Type,fresh(16),Payload,S) || Id <- holders(P),{ok,R} <- [maps:find(Id,Ps)]],
    case lists:member(ok,Results) of true -> ok;false -> {error,grant_holder_unavailable} end.
valid_name(Name) -> is_binary(Name) andalso byte_size(Name)>0 andalso byte_size(Name)=<128 andalso is_list(unicode:characters_to_list(Name)).
