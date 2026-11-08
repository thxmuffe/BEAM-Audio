%% Durable authority/Passport owner. Desks introduce; fresh authority proof grants operations.
-module(parvi_swarm_membership).
-behaviour(gen_server).
-export([start_link/0,status/0,current/0,invite/1,grant/2,revoke/1]).
-export([init/1,handle_call/3,handle_cast/2,handle_info/2,format_status/1]).
start_link() -> gen_server:start_link({local,?MODULE},?MODULE,[],[]).
status() -> gen_server:call(?MODULE,status).
current() -> gen_server:call(?MODULE,current).
invite(TTL) -> gen_server:call(?MODULE,{invite,TTL}).
grant(Device,Permissions) -> gen_server:call(?MODULE,{grant,Device,Permissions}).
revoke(Device) -> gen_server:call(?MODULE,{revoke,Device}).
init([]) ->
    {Pub,Private} = parvi_cluster_store:identity(),Id = binary:encode_hex(Pub),
    {ok,Config} = application:get_env(parvi,swarm_membership),
    Base = #{id => Id,private => Private,pending => #{},request => undefined,
             state => waiting,until => 0,rejected => 0,last_attempt => now_ms()-5000},
    S = boot(Config,Base),erlang:send_after(250,self(),tick),{ok,S}.
boot(#{mode := create,desks := URLs} = Config,S) ->
    ok = parvi_swarm_passport:urls(URLs),Id = maps:get(id,S),Primary = maps:get(desk,Config,hd(URLs)),
    Default = #{<<"v">> => 1,<<"type">> => <<"policy">>,<<"swarm">> => fresh(16),
        <<"authority">> => Id,<<"director">> => Id,<<"epoch">> => 1,<<"revision">> => 1,
        <<"members">> => #{Id => #{<<"membership">> => fresh(16),
            <<"permissions">> => [<<"capabilities_read">>,<<"job_offer">>,<<"status_read">>]}}},
    Saved = parvi_cluster_store:load(swarm_authority,#{policy => Default,invitations => #{},routes => #{}}),
    P = maps:get(policy,Saved),ok = parvi_swarm_passport:policy(P),Id = maps:get(<<"authority">>,P),
    Swarm = maps:get(<<"swarm">>,P),ok = parvi_swarm_desks:configure(Swarm,URLs,Primary,maps:get(routes,Saved)),
    Route = parvi_swarm_desks:route(),OldRoutes = maps:get(routes,Saved),Routes = OldRoutes#{Id => Route},
    CurrentPolicy = case maps:find(Id,OldRoutes) of
        {ok,OldRoute} when OldRoute =/= Route -> bump(P,false);
        _ -> P
    end,
    Next = S#{role => authority,policy => CurrentPolicy,invitations => maps:get(invitations,Saved),routes => Routes,
        urls => URLs,primary => Primary,swarm => Swarm,authority => Id,state := authorized,until := infinity},
    checkpoint_authority(Next),publish(Next),Next;
boot(#{mode := join,invitation := Link} = Config,S) ->
    {Ticket,I} = parvi_swarm_passport:parse_invitation(Link),
    Saved = parvi_cluster_store:load(swarm_member,undefined),
    case Saved of
        #{id := Id,swarm := Swarm} when Id =:= map_get(id,S),Swarm =:= map_get(<<"swarm">>,I) ->
            boot_saved(Config,Saved,S);
        undefined ->
            URLs = maps:get(<<"desks">>,I),Primary = maps:get(desk,Config,hd(URLs)),
            client(Ticket,maps:get(<<"authority">>,I),maps:get(<<"swarm">>,I),URLs,Primary,
                   maps:get(<<"route">>,I),#{},S)
    end;
boot(#{mode := resume} = Config,S) ->
    boot_saved(Config,parvi_cluster_store:load(swarm_member,undefined),S).
boot_saved(Config,#{id := Id,passport := Passport,authority := Authority,swarm := Swarm,
                   desks := URLs,primary := OldPrimary,authority_route := R} = Saved,#{id := Id} = S) ->
    _ = parvi_swarm_passport:passport(Passport,Authority,Id,Swarm),
    client(Passport,Authority,Swarm,URLs,maps:get(desk,Config,OldPrimary),R,maps:get(floor,Saved,#{}),S).
client(Credential,Authority,Swarm,URLs,Primary,AuthorityRoute,Floor,S) ->
    ok = parvi_swarm_passport:urls(URLs),true = lists:member(Primary,URLs),
    %% The authority registers the same identity/mailbox at every permitted Desk.
    R = AuthorityRoute#{<<"desk">> := Primary},
    ok = parvi_swarm_desks:configure(Swarm,URLs,Primary,#{Authority => R}),
    S#{role => member,credential => Credential,authority => Authority,authority_route => R,
       swarm => Swarm,urls => URLs,primary => Primary,floor => Floor,policy => undefined,routes => #{Authority => R}}.

handle_call(status,_,S) ->
    P = maps:get(policy,S),
    {reply,#{id => maps:get(id,S),swarm => maps:get(swarm,S),role => maps:get(role,S),
        state => maps:get(state,S),epoch => value(<<"epoch">>,P),revision => value(<<"revision">>,P),
        members => case P of undefined -> [];_ -> maps:keys(maps:get(<<"members">>,P)) end,
        rejected => maps:get(rejected,S)},S};
handle_call(current,_,#{state := authorized} = S) ->
    case maps:get(until,S) > now_ms() of
        true -> {reply,{ok,view(S)},S};false -> {reply,{error,authorization_expired},S}
    end;
handle_call(current,_,S) -> {reply,{error,maps:get(state,S)},S};
handle_call({invite,TTL},_,#{role := authority,policy := P,invitations := Invites} = S)
        when is_integer(TTL),TTL > 0,TTL =< 86400,map_size(Invites) < 32 ->
    Id = fresh(16),Secret = fresh(32),Expiry = erlang:system_time(second)+TTL,
    I = #{<<"v">> => 1,<<"type">> => <<"invitation">>,<<"swarm">> => maps:get(swarm,S),
        <<"authority">> => maps:get(id,S),<<"invite">> => Id,<<"secret">> => Secret,<<"expires">> => Expiry,
        <<"desks">> => maps:get(urls,S),<<"route">> => maps:get(maps:get(id,S),maps:get(routes,S))},
    Entry = #{hash => crypto:hash(sha256,Secret),expires => Expiry,claimed => undefined},
    Next = S#{invitations := Invites#{Id => Entry}},checkpoint_authority(Next),
    _ = P,{reply,{ok,parvi_swarm_passport:invitation(sign(I,S))},Next};
handle_call({grant,Device,Permissions},_,#{role := authority,policy := P} = S) ->
    try
        ok = parvi_swarm_passport:permissions(Permissions),Members = maps:get(<<"members">>,P),
        M = maps:get(Device,Members),NewP = bump(P#{<<"members">> := Members#{Device := M#{<<"permissions">> := Permissions}}},false),
        Next = S#{policy := NewP},checkpoint_authority(Next),changed(Next,maps:get(routes,S)),
        {reply,ok,Next}
    catch exit:{membership_storage_failed,_} = Reason -> exit(Reason);
          _:_ -> {reply,{error,invalid_grant},S} end;
handle_call({revoke,Device},_,#{role := authority,policy := P,routes := Routes,invitations := Invites} = S) ->
    case Device =/= maps:get(<<"authority">>,P) andalso Device =/= maps:get(<<"director">>,P)
         andalso maps:is_key(Device,maps:get(<<"members">>,P)) of
        false -> {reply,{error,invalid_revocation},S};
        true ->
            NewP = bump(P#{<<"members">> := maps:remove(Device,maps:get(<<"members">>,P))},true),
            Next = S#{policy := NewP,routes := maps:remove(Device,Routes),
                invitations := maps:filter(fun(_,E) -> maps:get(claimed,E) =/= Device end,Invites)},
            checkpoint_authority(Next),changed(Next,Routes),{reply,ok,Next}
    end;
handle_call(_,_,S) -> {reply,{error,unsupported},S}.
handle_cast(_,S) -> {noreply,S}.
handle_info(tick,S0) ->
    S1 = S0#{pending := maps:filter(fun(_,E) -> maps:get(deadline,E) > now_ms() end,maps:get(pending,S0))},
    S2 = case maps:get(role,S1) of
        authority -> S1;
        member -> client_tick(S1)
    end,
    erlang:send_after(250,self(),tick),{noreply,S2};
handle_info({desk_event,URL,disconnected},#{role := member,primary := URL} = S) ->
    invalidate(),{noreply,S#{state := waiting,until := 0,request := undefined}};
handle_info({desk_event,_,_},S) -> {noreply,S};
handle_info({desk_delivery,_,From,Packet},S) ->
    try
        B = parvi_swarm_passport:verify(Packet,From),
        parvi_swarm_passport:exact(B,[<<"v">>,<<"type">>,<<"from">>,<<"to">>,<<"swarm">>,<<"request">>,<<"payload">>]),
        #{<<"v">> := 1,<<"from">> := From,<<"to">> := To,<<"swarm">> := Swarm,<<"request">> := Req} = B,
        To = maps:get(id,S),Swarm = maps:get(swarm,S),true = hex(Req,32),
        {noreply,incoming(From,B,S)}
    catch exit:{membership_storage_failed,_} = Reason -> exit(Reason);
          _:_ -> {noreply,S#{rejected := maps:get(rejected,S)+1}} end;
handle_info(_,S) -> {noreply,S}.

client_tick(S) ->
    Now = now_ms(),Request = maps:get(request,S),
    Next = case maps:get(state,S) =:= authorized andalso Now >= maps:get(until,S) of
        true -> invalidate(),S#{state := waiting};false -> S end,
    Due = maps:get(state,Next) =/= revoked andalso Now-maps:get(last_attempt,Next) >= 5000 andalso
        (Request =:= undefined orelse Now >= maps:get(deadline,Request)),
    Refresh = maps:get(state,Next) =/= authorized orelse Now >= maps:get(until,Next)-30000,
    case Due andalso Refresh of
        false -> Next;
        true ->
            Req = fresh(16),Nonce = fresh(32),R = parvi_swarm_desks:route(),
            send(maps:get(authority,Next),maps:get(authority_route,Next),<<"hello">>,Req,
                #{<<"nonce">> => Nonce,<<"credential">> => maps:get(credential,Next),<<"route">> => R},Next),
            Next#{request := #{id => Req,nonce => Nonce,deadline => Now+10000},last_attempt := Now}
    end.
incoming(Peer,#{<<"type">> := <<"hello">>,<<"request">> := Req,<<"payload">> := Payload},
         #{role := authority,pending := Pending} = S) when map_size(Pending) < 16 ->
    parvi_swarm_passport:exact(Payload,[<<"nonce">>,<<"credential">>,<<"route">>]),
    Nonce = maps:get(<<"nonce">>,Payload),true = hex(Nonce,64),R = maps:get(<<"route">>,Payload),
    parvi_swarm_passport:route(R,maps:get(urls,S)),Credential = maps:get(<<"credential">>,Payload),
    case credential(Peer,Credential,S) of
        denied -> send(Peer,R,<<"denied">>,Req,#{<<"nonce">> => Nonce,<<"reason">> => <<"revoked">>},S),S;
        {ok,_} ->
            Challenge = fresh(32),Hash = binary:encode_hex(crypto:hash(sha256,Credential)),
            Data = #{<<"nonce">> => Nonce,<<"challenge">> => Challenge,<<"hash">> => Hash},
            send(Peer,R,<<"challenge">>,Req,Data,S),
            S#{pending := Pending#{Req => #{peer => Peer,route => R,credential => Credential,data => Data,deadline => now_ms()+10000}}}
    end;
incoming(Peer,#{<<"type">> := <<"proof">>,<<"request">> := Req,<<"payload">> := Data},#{role := authority} = S) ->
    #{peer := Peer,route := R,credential := Credential,data := Data,deadline := Deadline} = maps:get(Req,maps:get(pending,S)),
    true = now_ms() < Deadline,
    {ok,Kind} = credential(Peer,Credential,S),
    Next = admit(Peer,R,Credential,Kind,S#{pending := maps:remove(Req,maps:get(pending,S))}),
    P = maps:get(policy,Next),M = maps:get(Peer,maps:get(<<"members">>,P)),
    Passport = sign(#{<<"v">> => 1,<<"type">> => <<"passport">>,<<"swarm">> => maps:get(swarm,S),
        <<"authority">> => maps:get(id,S),<<"device">> => Peer,<<"membership">> => maps:get(<<"membership">>,M),
        <<"epoch">> => maps:get(<<"epoch">>,P)},Next),
    Grant = #{<<"nonce">> => maps:get(<<"nonce">>,Data),<<"challenge">> => maps:get(<<"challenge">>,Data),
              <<"passport">> => Passport,<<"policy">> => sign(P,Next),<<"routes">> => maps:get(routes,Next)},
    send(Peer,R,<<"grant">>,Req,Grant,Next),Next;
incoming(Authority,#{<<"type">> := <<"challenge">>,<<"request">> := Req,<<"payload">> := Data},
         #{role := member,authority := Authority,request := #{id := Req,nonce := Nonce,deadline := Deadline} = Request} = S) ->
    true = now_ms() < Deadline,parvi_swarm_passport:exact(Data,[<<"nonce">>,<<"challenge">>,<<"hash">>]),
    Nonce = maps:get(<<"nonce">>,Data),true = hex(maps:get(<<"challenge">>,Data),64),
    Expected = binary:encode_hex(crypto:hash(sha256,maps:get(credential,S))),Expected = maps:get(<<"hash">>,Data),
    send(Authority,maps:get(authority_route,S),<<"proof">>,Req,Data,S),
    S#{request := Request#{challenge => maps:get(<<"challenge">>,Data)}};
incoming(Authority,#{<<"type">> := <<"grant">>,<<"request">> := Req,<<"payload">> := G},
         #{role := member,authority := Authority,request := #{id := Req,nonce := Nonce,challenge := Challenge,deadline := Deadline}} = S) ->
    true = now_ms() < Deadline,parvi_swarm_passport:exact(G,[<<"nonce">>,<<"challenge">>,<<"passport">>,<<"policy">>,<<"routes">>]),
    Nonce = maps:get(<<"nonce">>,G),Challenge = maps:get(<<"challenge">>,G),
    P = parvi_swarm_passport:verify(maps:get(<<"policy">>,G),Authority),ok = parvi_swarm_passport:policy(P),
    Authority = maps:get(<<"authority">>,P),Swarm = maps:get(swarm,S),Swarm = maps:get(<<"swarm">>,P),
    Passport = maps:get(<<"passport">>,G),Pass = parvi_swarm_passport:passport(Passport,Authority,maps:get(id,S),Swarm),
    #{<<"membership">> := Mid} = maps:get(maps:get(id,S),maps:get(<<"members">>,P)),Mid = maps:get(<<"membership">>,Pass),
    Epoch = maps:get(<<"epoch">>,P),Epoch = maps:get(<<"epoch">>,Pass),
    Floor = maps:get(floor,S),true = Epoch >= maps:get(epoch,Floor,0),
    true = maps:get(<<"revision">>,P) >= maps:get(revision,Floor,0),
    Routes = maps:get(<<"routes">>,G),true = map_size(Routes) =:= map_size(maps:get(<<"members">>,P)),
    true = lists:sort(maps:keys(Routes)) =:= lists:sort(maps:keys(maps:get(<<"members">>,P))),
    maps:foreach(fun(_,R) -> parvi_swarm_passport:route(R,maps:get(urls,S)) end,Routes),
    NewFloor = #{epoch => Epoch,revision => maps:get(<<"revision">>,P)},
    Saved = #{id => maps:get(id,S),passport => Passport,authority => Authority,swarm => Swarm,
        desks => maps:get(urls,S),primary => maps:get(primary,S),authority_route => maps:get(authority_route,S),floor => NewFloor},
    ok = save(swarm_member,Saved),
    ok = parvi_swarm_desks:configure(Swarm,maps:get(urls,S),maps:get(primary,S),Routes),
    Next = S#{credential := Passport,policy := P,routes := Routes,floor := NewFloor,request := undefined,
              state := authorized,until := Deadline+50000},publish(Next),Next;
incoming(Authority,#{<<"type">> := <<"denied">>,<<"request">> := Req,<<"payload">> := D},
         #{role := member,authority := Authority,request := #{id := Req,nonce := Nonce,deadline := Deadline}} = S) ->
    true = now_ms() < Deadline,parvi_swarm_passport:exact(D,[<<"nonce">>,<<"reason">>]),
    Nonce = maps:get(<<"nonce">>,D),<<"revoked">> = maps:get(<<"reason">>,D),
    invalidate(),S#{state := revoked,until := 0,request := undefined};
incoming(Authority,#{<<"type">> := <<"changed">>,<<"payload">> := D},#{role := member,authority := Authority} = S) ->
    parvi_swarm_passport:exact(D,[<<"epoch">>,<<"revision">>]),
    [begin N = maps:get(K,D),true = is_integer(N) andalso N > 0 andalso N =< 9007199254740991 end
        || K <- [<<"epoch">>,<<"revision">>]],
    Floor = maps:get(floor,S),
    case maps:get(<<"epoch">>,D) > maps:get(epoch,Floor,0) orelse maps:get(<<"revision">>,D) > maps:get(revision,Floor,0) of
        true -> invalidate(),S#{state := waiting,until := 0,request := undefined,last_attempt := now_ms()-5000};
        false -> S
    end;
incoming(_,_,_) -> error(unexpected_membership_message).

credential(Peer,Packet,S) ->
    try
        P = parvi_swarm_passport:verify(Packet,maps:get(id,S)),Swarm = maps:get(swarm,S),Swarm = maps:get(<<"swarm">>,P),
        case maps:get(<<"type">>,P) of
            <<"passport">> ->
                Pass = parvi_swarm_passport:passport(Packet,maps:get(id,S),Peer,Swarm),
                #{<<"membership">> := Mid} = maps:get(Peer,maps:get(<<"members">>,maps:get(policy,S))),
                Mid = maps:get(<<"membership">>,Pass),true = maps:get(<<"epoch">>,Pass) =< maps:get(<<"epoch">>,maps:get(policy,S)),
                {ok,passport};
            <<"invitation">> ->
                {_,P} = parvi_swarm_passport:parse_invitation(parvi_swarm_passport:invitation(Packet)),
                E = maps:get(maps:get(<<"invite">>,P),maps:get(invitations,S)),
                true = maps:get(expires,E) > erlang:system_time(second),
                true = maps:get(claimed,E) =:= undefined orelse maps:get(claimed,E) =:= Peer,
                true = crypto:hash_equals(maps:get(hash,E),crypto:hash(sha256,maps:get(<<"secret">>,P))),{ok,invitation}
        end
    catch _:_ -> denied end.
admit(Peer,R,Credential,Kind,#{policy := P,routes := Routes,invitations := Invites} = S) ->
    Members = maps:get(<<"members">>,P),true = map_size(Members) < 16 orelse maps:is_key(Peer,Members),
    M = maps:get(Peer,Members,#{<<"membership">> => fresh(16),<<"permissions">> => []}),
    Updated = not maps:is_key(Peer,Members) orelse maps:get(Peer,Routes,undefined) =/= R,
    NewP = case Updated of true -> bump(P#{<<"members">> := Members#{Peer => M}},false);false -> P end,
    NewInvites = case Kind of
        passport -> Invites;
        invitation ->
            B = parvi_swarm_passport:verify(Credential,maps:get(id,S)),I = maps:get(<<"invite">>,B),
            Invites#{I := (maps:get(I,Invites))#{claimed := Peer}}
    end,
    Next = S#{policy := NewP,routes := Routes#{Peer => R},invitations := NewInvites},
    checkpoint_authority(Next),
    case Updated of true -> changed(Next,maps:remove(Peer,Routes));false -> ok end,Next.
bump(P,Revoke) -> P#{<<"revision">> := maps:get(<<"revision">>,P)+1,
    <<"epoch">> := maps:get(<<"epoch">>,P)+case Revoke of true -> 1;false -> 0 end}.
changed(S,Routes) ->
    ok = parvi_swarm_desks:configure(maps:get(swarm,S),maps:get(urls,S),maps:get(primary,S),maps:get(routes,S)),
    P = maps:get(policy,S),
    maps:foreach(fun(Peer,R) ->
        case Peer =:= maps:get(id,S) of true -> ok;false ->
            send(Peer,R,<<"changed">>,fresh(16),maps:with([<<"epoch">>,<<"revision">>],P),S)
        end
    end,Routes),publish(S).
checkpoint_authority(S) -> save(swarm_authority,maps:with([policy,invitations,routes],S)).
save(Name,Data) ->
    try parvi_cluster_store:save(Name,Data)
    catch _:_ -> exit({membership_storage_failed,Name}) end.
view(S) -> #{policy => parvi_swarm_passport:runtime_policy(maps:get(policy,S),maps:get(id,S)),
              routes => maps:remove(maps:get(id,S),maps:get(routes,S)),until => maps:get(until,S)}.
publish(S) -> notify({membership_authorized,view(S)}).
invalidate() -> notify(membership_invalidated).
notify(Event) -> case whereis(parvi_swarm_control) of undefined -> ok;Pid -> Pid ! Event end.
send(To,R,Type,Request,Payload,S) ->
    Body = #{<<"v">> => 1,<<"type">> => Type,<<"from">> => maps:get(id,S),<<"to">> => To,
             <<"swarm">> => maps:get(swarm,S),<<"request">> => Request,<<"payload">> => Payload},
    parvi_swarm_desks:send_route(To,R,<<"membership">>,sign(Body,S)).
sign(B,S) -> parvi_swarm_passport:sign(B,maps:get(private,S)).
value(_,undefined) -> null;
value(K,P) -> maps:get(K,P).
fresh(N) -> binary:encode_hex(crypto:strong_rand_bytes(N)).
hex(B,N) -> parvi_swarm_job:hex(B,N).
now_ms() -> erlang:monotonic_time(millisecond).
format_status(Status) -> maps:map(fun(state,S) -> maps:with([id,swarm,role,state],S);(log,_) -> [];(_,_) -> redacted end,Status).
