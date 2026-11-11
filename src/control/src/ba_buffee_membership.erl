%% Trusted Owners administer roles; participation, presence and connections
%% remain separate. Ownership survives leaving and application shutdown.
-module(ba_buffee_membership).
-behaviour(gen_server).
-export([start_link/0,status/0,current/0,invite/1,invite_devices/2,depart/0,grant/2,revoke/1,set_role/2]).
-export([init/1,handle_call/3,handle_cast/2,handle_info/2,format_status/1]).
start_link() -> gen_server:start_link({local,?MODULE},?MODULE,[],[]).
status() -> gen_server:call(?MODULE,status).
current() -> gen_server:call(?MODULE,current).
invite(TTL) -> gen_server:call(?MODULE,{invite,TTL}).
depart() -> gen_server:call(?MODULE,depart).
invite_devices(Ids,TTL) -> gen_server:call(?MODULE,{invite_devices,Ids,TTL}).
grant(Device,Permissions) -> gen_server:call(?MODULE,{grant,Device,Permissions}).
revoke(Device) -> gen_server:call(?MODULE,{revoke,Device}).
set_role(Device,Role) -> gen_server:call(?MODULE,{set_role,Device,Role}).
init([]) ->
    {Pub,Private} = ba_device_store:identity(),Id = binary:encode_hex(Pub),
    {ok,Config} = application:get_env(ba_core,buffee_membership),
    Base = #{id => Id,private => Private,pending => #{},request => undefined,
             state => waiting,until => 0,rejected => 0,last_attempt => now_ms()-5000},
    S = boot(Config,Base),erlang:send_after(250,self(),tick),{ok,S}.
boot(#{mode := create,desks := URLs} = Config,S) ->
    ok = ba_buffee_passport:urls(URLs),Id = maps:get(id,S),Primary = maps:get(desk,Config,hd(URLs)),
    Default = #{<<"v">> => 1,<<"type">> => <<"policy">>,<<"buffee">> => maps:get(buffee,Config,fresh(16)),
        <<"authority">> => Id,<<"manager">> => Id,<<"epoch">> => 1,<<"revision">> => 1,
        <<"members">> => #{Id => #{<<"membership">> => fresh(16),
            <<"permissions">> => ba_buffee_roles:initial(application:get_env(ba_core,buffee_default_permissions,[<<"capabilities_read">>,<<"job_offer">>,<<"status_read">>]))}}},
    Saved = ba_device_store:load(buffee_authority,#{policy => Default,invitations => #{},routes => #{}}),
    P = maps:get(policy,Saved),ok = ba_buffee_passport:policy(P),true = ba_buffee_roles:owner(Id,P),
    Buffee = maps:get(<<"buffee">>,P),ok = ba_buffee_desks:configure(Buffee,URLs,Primary,maps:get(routes,Saved)),
    Route = ba_buffee_desks:route(),Routes = (maps:get(routes,Saved))#{Id => Route},
    CurrentPolicy = P,
    Next = S#{role => authority,name => maps:get(name,Config),policy => CurrentPolicy,invitations => maps:get(invitations,Saved),routes => Routes,
        urls => URLs,primary => Primary,buffee => Buffee,authority => Id,state := authorized,until := infinity},
    Ready=case maps:find(reusable,Config) of
        {ok,Link} ->
            {_,I}=ba_buffee_passport:parse_invitation(Link),
            ok=ba_buffee_desks:advertise(maps:get(<<"mailbox">>,maps:get(<<"route">>,I))),
            Entry=#{hash => crypto:hash(sha256,maps:get(<<"secret">>,I)),
                    issuer => maps:get(<<"authority">>,I),blocked => []},
            Next#{reusable_link => Link,invitations := #{maps:get(<<"invite">>,I) => Entry}};
        error -> Next
    end,
    checkpoint_authority(Ready),publish(Ready),Ready;
boot(#{mode := recover_authority,snapshot := Snapshot},S) ->
    %% Ownership survives app shutdown. No surviving-peer ceremony is needed.
    ok=save(buffee_authority,maps:with([policy,invitations,routes],Snapshot)),
    Seed=maps:merge(S,maps:with([reusable_link],Snapshot)),
    Ready=boot(#{mode => create,name => maps:get(name,Snapshot),desks => maps:get(urls,Snapshot),
           desk => maps:get(primary,Snapshot)},Seed),
    announce(Ready),Ready;
boot(#{mode := join,invitation := Link} = Config,S) ->
    {Ticket,I} = ba_buffee_passport:parse_invitation(Link),
    Saved = ba_device_store:load(buffee_member,undefined),
    case Saved of
        #{id := Id,buffee := Buffee} when Id =:= map_get(id,S),Buffee =:= map_get(<<"buffee">>,I) ->
            boot_saved(Config,Saved,S#{name => maps:get(<<"name">>,I)});
        undefined ->
            URLs = maps:get(<<"desks">>,I),Primary = maps:get(desk,Config,hd(URLs)),
            Buffee=maps:get(<<"buffee">>,I),
            ok=ba_buffee_desks:configure(Buffee,URLs,Primary,#{}),
            S#{role => discovering,credential => Ticket,reusable_link => Link,invitation => I,
               name => maps:get(<<"name">>,I),authority => maps:get(<<"authority">>,I),
               buffee => Buffee,urls => URLs,primary => Primary,policy => undefined,routes => #{}}
    end;
boot(#{mode := rejoin,name := Name,member := Saved}=Config,S) ->
    boot_saved(Config,Saved,S#{name => Name});
boot(#{mode := resume},_S) ->
    error(ephemeral_buffees_cannot_be_resumed).
boot_saved(Config,#{id := Id,passport := Passport,authority := Authority,buffee := Buffee,
                   desks := URLs,primary := OldPrimary,authority_route := R} = Saved,#{id := Id} = S) ->
    Envelope=ba_buffee_passport:decode(Passport),
    Body=ba_buffee_passport:decode(base64:decode(maps:get(<<"body">>,Envelope))),
    _ = ba_buffee_passport:passport(Passport,maps:get(<<"authority">>,Body),Id,Buffee),
    client(Passport,Authority,Buffee,URLs,maps:get(desk,Config,OldPrimary),R,maps:get(floor,Saved,#{}),S).
client(Credential,Authority,Buffee,URLs,Primary,AuthorityRoute,Floor,S) ->
    ok = ba_buffee_passport:urls(URLs),true = lists:member(Primary,URLs),
    %% The authority registers the same identity/mailbox at every permitted Desk.
    R = AuthorityRoute#{<<"desk">> := Primary},
    ok = ba_buffee_desks:configure(Buffee,URLs,Primary,#{Authority => R}),
    S#{role => member,credential => Credential,authority => Authority,authority_route => R,
       buffee => Buffee,urls => URLs,primary => Primary,owner_deadline => now_ms()+30000,floor => Floor,policy => undefined,routes => #{Authority => R}}.

handle_call(status,_,S) ->
    P = maps:get(policy,S),
    {reply,#{id => maps:get(id,S),buffee => maps:get(buffee,S),role => public_role(S),roles => public_roles(S),owners => owners(P),
        name => maps:get(name,S),owner => maps:get(authority,S),
        state => maps:get(state,S),owner_present => owner_present(S),epoch => value(<<"epoch">>,P),revision => value(<<"revision">>,P),
        members => case P of undefined -> [];_ -> maps:keys(maps:get(<<"members">>,P)) end,
        membership => case P of undefined -> null;_ ->
            maps:get(<<"membership">>,maps:get(maps:get(id,S),maps:get(<<"members">>,P)),null) end,
        rejected => maps:get(rejected,S)},S};
handle_call(current,_,#{state := authorized} = S) ->
    {reply,{ok,view(S)},S};
handle_call(current,_,S) -> {reply,{error,maps:get(state,S)},S};
handle_call({invite,_},_,#{role := authority,reusable_link := Link}=S) ->
    {reply,{ok,compact_link(Link)},S};
handle_call({invite,TTL},_,S) ->
    case invitations([undefined],TTL,S) of
        {ok,[#{invitation := Link}],Next} -> {reply,{ok,Link},Next#{reusable_link => Link}};
        {error,R} -> {reply,{error,R},S}
    end;
handle_call({invite_devices,Ids,TTL},_,S) ->
    case invitations(Ids,TTL,S) of
        {ok,Links,Next} -> {reply,{ok,Links},Next};
        {error,R} -> {reply,{error,R},S}
    end;
handle_call(depart,_,#{role := authority,routes := Routes}=S) ->
    maps:foreach(fun(Peer,R) ->
        case Peer=:=maps:get(id,S) of
            true -> ok;
            false ->
                M=maps:get(Peer,maps:get(<<"members">>,maps:get(policy,S))),
                send(Peer,R,<<"ended">>,fresh(16),#{<<"membership">> => maps:get(<<"membership">>,M)},S)
        end
    end,Routes),{reply,ok,S};
handle_call(depart,_,#{role := member}=S) ->
    %% Bind departure to this admission: replaying an old signed leave must not
    %% evict the same Device after it accepts a fresh invitation.
    case maps:get(policy,S) of
        undefined -> ok;
        P ->
            M = maps:get(maps:get(id,S),maps:get(<<"members">>,P)),
            send(maps:get(authority,S),maps:get(authority_route,S),<<"leave">>,fresh(16),
                #{<<"membership">> => maps:get(<<"membership">>,M)},S)
    end,{reply,ok,S};
handle_call({set_role,Device,Role},_,#{role := authority,policy := P}=S) ->
    case ba_buffee_roles:change(maps:get(id,S),Device,Role,P) of
        {ok,Updated} ->
            NewP=bump(Updated,false),
            Next=owned_update(NewP,S),checkpoint_authority(Next),
            changed(Next,maps:get(routes,S)),{reply,ok,Next};
        Error -> {reply,Error,S}
    end;
handle_call({grant,Device,Permissions},_,#{role := authority,policy := P} = S) ->
    try
        true = ba_buffee_roles:owner(maps:get(id,S),P),
        ok = ba_buffee_passport:permissions(Permissions),Members = maps:get(<<"members">>,P),
        M = maps:get(Device,Members),NewP = bump(P#{<<"members">> := Members#{Device := M#{<<"permissions">> := Permissions}}},false),
        Next = owned_update(NewP,S),checkpoint_authority(Next),changed(Next,maps:get(routes,S)),
        {reply,ok,Next}
    catch exit:{membership_storage_failed,_} = Reason -> exit(Reason);
          _:_ -> {reply,{error,invalid_grant},S} end;
handle_call({revoke,Device},_,#{role := authority,policy := P,routes := Routes,invitations := Invites} = S) ->
    case ba_buffee_roles:owner(maps:get(id,S),P) andalso Device=/=maps:get(id,S) andalso maps:is_key(Device,maps:get(<<"members">>,P)) of
        false -> {reply,{error,invalid_revocation},S};
        true ->
            Manager=case maps:get(<<"manager">>,P) of Device -> maps:get(<<"authority">>,P);Existing -> Existing end,
            NewP = bump(P#{<<"manager">> := Manager,<<"members">> := maps:remove(Device,maps:get(<<"members">>,P))},true),
            Next = S#{policy := NewP,routes := maps:remove(Device,Routes),
                invitations := maps:map(fun(_,E) -> E#{blocked => lists:usort([Device|maps:get(blocked,E,[])])} end,Invites)},
            checkpoint_authority(Next),changed(Next,Routes),{reply,ok,Next}
    end;
handle_call({set_role,_,_},_,S) -> {reply,{error,owner_only},S};
handle_call(_,_,S) -> {reply,{error,unsupported},S}.
handle_cast(_,S) -> {noreply,S}.
handle_info(tick,S0) ->
    S1 = S0#{pending := maps:filter(fun(_,E) -> maps:get(deadline,E) > now_ms() end,maps:get(pending,S0))},
    S2 = case maps:get(role,S1) of
        discovering -> discover(S1);
        authority -> S1;
        member -> client_tick(S1)
    end,
    erlang:send_after(250,self(),tick),{noreply,S2};
handle_info({desk_event,_,connected},#{role := authority}=S) ->
    announce(S),{noreply,S};
handle_info({desk_event,URL,connected},#{role := member,primary := URL,state := waiting}=S) ->
    %% Do not wait for the retry timer after the Desk becomes usable.
    {noreply,client_refresh(S#{last_attempt := now_ms()-5000,request := undefined})};
handle_info({desk_event,URL,disconnected},#{role := member,primary := URL} = S) ->
    {noreply,S};
handle_info({desk_event,_,_},S) -> {noreply,S};
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

discover(#{last_attempt := Last}=S) ->
    case now_ms()-Last >= 1000 of
        false -> S;
        true ->
            I=maps:get(invitation,S),R=maps:get(<<"route">>,I),
            URL=maps:get(<<"desk">>,R),Cap=maps:get(<<"mailbox">>,R),
            Next=S#{last_attempt := now_ms()},
            case ba_buffee_desks:lookup(URL,Cap) of
                {ok,[]} -> Next;
                {ok,[Owner|_]} ->
                    client(maps:get(credential,S),Owner,maps:get(buffee,S),maps:get(urls,S),URL,R,#{},Next);
                {error,_} -> Next
            end
    end.

client_tick(S) -> client_refresh(S).
client_refresh(S) ->
    Now = now_ms(),Request = maps:get(request,S),Next=S,
    Due = maps:get(state,Next) =/= revoked andalso Now-maps:get(last_attempt,Next) >= 5000 andalso
        (Request =:= undefined orelse Now >= maps:get(deadline,Request)),
    Refresh = maps:get(state,Next) =/= authorized orelse Now >= maps:get(until,Next)-30000,
    case Due andalso Refresh of
        false -> Next;
        true ->
            Req = fresh(16),Nonce = fresh(32),R = ba_buffee_desks:route(),
            send(maps:get(authority,Next),maps:get(authority_route,Next),<<"hello">>,Req,
                #{<<"nonce">> => Nonce,<<"credential">> => maps:get(credential,Next),<<"route">> => R},Next),
            Next#{request := #{id => Req,nonce => Nonce,deadline => Now+10000},last_attempt := Now}
    end.
incoming(Peer,#{<<"type">> := <<"presence">>,<<"payload">> := Data},#{policy := P,routes := Routes}=S) when is_map(P) ->
    true=maps:is_key(Peer,maps:get(<<"members">>,P)),
    ba_buffee_passport:exact(Data,[<<"route">>]),R=maps:get(<<"route">>,Data),
    ok=ba_buffee_passport:route(R,maps:get(urls,S)),
    Next=S#{routes := Routes#{Peer => R}},
    ok=ba_buffee_desks:configure(maps:get(buffee,S),maps:get(urls,S),maps:get(primary,S),maps:get(routes,Next)),
    send(Peer,R,<<"policy">>,fresh(16),policy_state(Next),Next),Next;
incoming(Peer,#{<<"type">> := <<"policy">>,<<"payload">> := Data},#{policy := Current}=S) when is_map(Current) ->
    true=maps:is_key(Peer,maps:get(<<"members">>,Current)),
    ba_buffee_passport:exact(Data,[<<"state">>,<<"signer">>]),
    Signer=maps:get(<<"signer">>,Data),true=ba_buffee_roles:owner(Signer,Current),
    Statement=ba_buffee_passport:verify(maps:get(<<"state">>,Data),Signer),
    ba_buffee_passport:exact(Statement,[<<"policy">>,<<"routes">>,<<"invitations">>]),
    P=maps:get(<<"policy">>,Statement),ok=ba_buffee_passport:policy(P),
    true=maps:get(<<"buffee">>,P)=:=maps:get(buffee,S),
    true=maps:get(<<"authority">>,P)=:=maps:get(<<"authority">>,Current),
    true=maps:get(<<"revision">>,P)>=maps:get(<<"revision">>,Current),
    true=maps:get(<<"revision">>,P)>maps:get(<<"revision">>,Current) orelse P=:=Current,
    Routes0=maps:get(<<"routes">>,Statement),
    Routes=case maps:is_key(maps:get(id,S),maps:get(<<"members">>,P)) of
        true -> Routes0#{(maps:get(id,S)) => ba_buffee_desks:route()};false -> Routes0 end,
    maps:foreach(fun(Id,R) -> true=maps:is_key(Id,maps:get(<<"members">>,P)),
        ba_buffee_passport:route(R,maps:get(urls,S)) end,Routes),
    Id=maps:get(id,S),
    case maps:is_key(Id,maps:get(<<"members">>,P)) of
        false -> invalidate(),ba_buffee:ended(self()),S#{state := revoked,until := 0};
        true ->
            Role=case ba_buffee_roles:owner(Id,P) of true -> authority;false -> member end,
            Next=S#{policy := P,routes := Routes,role := Role,policy_signer => Signer,signed_state => maps:get(<<"state">>,Data),
                invitations => read_invitation_state(maps:get(<<"invitations">>,Statement))},
            case Role of authority -> checkpoint_authority(Next);member -> checkpoint_member(Next) end,
            ok=ba_buffee_desks:configure(maps:get(buffee,S),maps:get(urls,S),maps:get(primary,S),Routes),
            publish(Next),Next
    end;
incoming(Peer,#{<<"type">> := <<"hello">>,<<"request">> := Req,<<"payload">> := Payload},
         #{role := authority,pending := Pending} = S) when map_size(Pending) < 16 ->
    ba_buffee_passport:exact(Payload,[<<"nonce">>,<<"credential">>,<<"route">>]),
    Nonce = maps:get(<<"nonce">>,Payload),true = hex(Nonce,64),R = maps:get(<<"route">>,Payload),
    ba_buffee_passport:route(R,maps:get(urls,S)),Credential = maps:get(<<"credential">>,Payload),
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
    Passport = sign(#{<<"v">> => 1,<<"type">> => <<"passport">>,<<"buffee">> => maps:get(buffee,S),
        <<"authority">> => maps:get(id,S),<<"device">> => Peer,<<"membership">> => maps:get(<<"membership">>,M),
        <<"epoch">> => maps:get(<<"epoch">>,P)},Next),
    Grant = #{<<"nonce">> => maps:get(<<"nonce">>,Data),<<"challenge">> => maps:get(<<"challenge">>,Data),
              <<"passport">> => Passport,<<"policy">> => sign(owner_statement(P,Next),Next),<<"routes">> => maps:get(routes,Next)},
    send(Peer,R,<<"grant">>,Req,Grant,Next),Next;
incoming(Authority,#{<<"type">> := <<"challenge">>,<<"request">> := Req,<<"payload">> := Data},
         #{role := member,authority := Authority,request := #{id := Req,nonce := Nonce,deadline := Deadline} = Request} = S) ->
    true = now_ms() < Deadline,ba_buffee_passport:exact(Data,[<<"nonce">>,<<"challenge">>,<<"hash">>]),
    Nonce = maps:get(<<"nonce">>,Data),true = hex(maps:get(<<"challenge">>,Data),64),
    Expected = binary:encode_hex(crypto:hash(sha256,maps:get(credential,S))),Expected = maps:get(<<"hash">>,Data),
    send(Authority,maps:get(authority_route,S),<<"proof">>,Req,Data,S),
    S#{request := Request#{challenge => maps:get(<<"challenge">>,Data)}};
incoming(Authority,#{<<"type">> := <<"grant">>,<<"request">> := Req,<<"payload">> := G},
         #{role := member,authority := Authority,request := #{id := Req,nonce := Nonce,challenge := Challenge,deadline := Deadline}} = S) ->
    true = now_ms() < Deadline,ba_buffee_passport:exact(G,[<<"nonce">>,<<"challenge">>,<<"passport">>,<<"policy">>,<<"routes">>]),
    Nonce = maps:get(<<"nonce">>,G),Challenge = maps:get(<<"challenge">>,G),
    Statement = ba_buffee_passport:verify(maps:get(<<"policy">>,G),Authority),
    ba_buffee_passport:exact(Statement,[<<"policy">>,<<"routes">>,<<"invitations">>]),
    P=maps:get(<<"policy">>,Statement),ok = ba_buffee_passport:policy(P),
    true = ba_buffee_roles:owner(Authority,P),Buffee = maps:get(buffee,S),Buffee = maps:get(<<"buffee">>,P),
    Passport = maps:get(<<"passport">>,G),Pass = ba_buffee_passport:passport(Passport,Authority,maps:get(id,S),Buffee),
    #{<<"membership">> := Mid} = maps:get(maps:get(id,S),maps:get(<<"members">>,P)),Mid = maps:get(<<"membership">>,Pass),
    Epoch = maps:get(<<"epoch">>,P),Epoch = maps:get(<<"epoch">>,Pass),
    Floor = maps:get(floor,S),true = Epoch >= maps:get(epoch,Floor,0),
    true = maps:get(<<"revision">>,P) >= maps:get(revision,Floor,0),
    Routes = maps:get(<<"routes">>,G),true = map_size(Routes) =< map_size(maps:get(<<"members">>,P)),
    true = lists:all(fun(D) -> maps:is_key(D,maps:get(<<"members">>,P)) end,maps:keys(Routes)),
    maps:foreach(fun(_,R) -> ba_buffee_passport:route(R,maps:get(urls,S)) end,Routes),
    NewFloor = #{epoch => Epoch,revision => maps:get(<<"revision">>,P)},
    Saved = #{id => maps:get(id,S),passport => Passport,authority => Authority,buffee => Buffee,
        desks => maps:get(urls,S),primary => maps:get(primary,S),authority_route => maps:get(authority_route,S),floor => NewFloor},
    ok = save(buffee_member,Saved),
    ba_buffee:remember(self(),maps:get(name,S),Saved),
    ok = ba_buffee_desks:configure(Buffee,maps:get(urls,S),maps:get(primary,S),Routes),
    Mode=case ba_buffee_roles:owner(maps:get(id,S),P) of true -> authority;false -> member end,
    Next = S#{credential := Passport,policy := P,routes := Routes,floor := NewFloor,request := undefined,
              role := Mode,invitations => read_invitation_state(maps:get(<<"invitations">>,Statement)),policy_signer => Authority,signed_state => maps:get(<<"policy">>,G),state := authorized,until := Deadline+50000,owner_deadline := Deadline+50000},
    case Mode of authority -> checkpoint_authority(Next);member -> ok end,publish(Next),Next;
incoming(Authority,#{<<"type">> := <<"denied">>,<<"request">> := Req,<<"payload">> := D},
         #{role := member,authority := Authority,request := #{id := Req,nonce := Nonce,deadline := Deadline}} = S) ->
    true = now_ms() < Deadline,ba_buffee_passport:exact(D,[<<"nonce">>,<<"reason">>]),
    Nonce = maps:get(<<"nonce">>,D),<<"revoked">> = maps:get(<<"reason">>,D),
    invalidate(),S#{state := revoked,until := 0,request := undefined};
incoming(Owner,#{<<"type">> := <<"ended">>,<<"payload">> := P},#{policy := Policy}=S) ->
    true=ba_buffee_roles:owner(Owner,Policy),
    ba_buffee_passport:exact(P,[<<"membership">>]),
    Membership=maps:get(<<"membership">>,maps:get(maps:get(id,S),maps:get(<<"members">>,maps:get(policy,S)))),
    Membership=maps:get(<<"membership">>,P),
    invalidate(),ba_buffee:ended(self()),S#{state := ended,until := 0};
incoming(Peer,#{<<"type">> := <<"leave">>,<<"payload">> := Payload},
         #{role := authority,policy := P,routes := Routes}=S) ->
    ba_buffee_passport:exact(Payload,[<<"membership">>]),true = Peer=/=maps:get(id,S),
    #{<<"membership">> := Membership} = maps:get(Peer,maps:get(<<"members">>,P)),
    Membership = maps:get(<<"membership">>,Payload),
    NewP = bump(P,false),
    Next = S#{policy := NewP,routes := maps:remove(Peer,Routes)},
    checkpoint_authority(Next),changed(Next,Routes),Next;
incoming(_,_,_) -> error(unexpected_membership_message).

credential(Peer,Packet,S) ->
    try
        Envelope=ba_buffee_passport:decode(Packet),P0=ba_buffee_passport:decode(base64:decode(maps:get(<<"body">>,Envelope))),
        Buffee = maps:get(buffee,S),Buffee = maps:get(<<"buffee">>,P0),
        case maps:get(<<"type">>,P0) of
            <<"passport">> ->
                Signer=maps:get(<<"authority">>,P0),
                Pass = ba_buffee_passport:passport(Packet,Signer,Peer,Buffee),
                #{<<"membership">> := Mid} = maps:get(Peer,maps:get(<<"members">>,maps:get(policy,S))),
                Mid = maps:get(<<"membership">>,Pass),true = maps:get(<<"epoch">>,Pass) =< maps:get(<<"epoch">>,maps:get(policy,S)),
                {ok,passport};
            <<"invitation">> ->
                {_,P} = ba_buffee_passport:parse_invitation(ba_buffee_passport:invitation(Packet)),
                E = maps:get(maps:get(<<"invite">>,P),maps:get(invitations,S)),
                true = maps:get(issuer,E,maps:get(id,S)) =:= maps:get(<<"authority">>,P),
                false = lists:member(Peer,maps:get(blocked,E,[])),
                true = crypto:hash_equals(maps:get(hash,E),crypto:hash(sha256,maps:get(<<"secret">>,P))),{ok,invitation}
        end
    catch _:_ -> denied end.
admit(Peer,R,_Credential,_Kind,#{policy := P,routes := Routes}=S) ->
    Members = maps:get(<<"members">>,P),true = map_size(Members) < 16 orelse maps:is_key(Peer,Members),
    M = maps:get(Peer,Members,#{<<"membership">> => fresh(16),<<"permissions">> => application:get_env(ba_core,buffee_default_permissions,[])}),
    Updated = not maps:is_key(Peer,Members) orelse maps:get(Peer,Routes,undefined) =/= R,
    Admission=case Updated of true -> M#{<<"membership">> := fresh(16)};false -> M end,
    NewP = case Updated of true -> bump(P#{<<"members">> := Members#{Peer => Admission}},false);false -> P end,
    Next = S#{policy := NewP,routes := Routes#{Peer => R}},
    checkpoint_authority(Next),
    case Updated of true -> changed(Next,maps:remove(Peer,Routes));false -> ok end,Next.

bump(P,Revoke) -> P#{<<"revision">> := maps:get(<<"revision">>,P)+1,
    <<"epoch">> := maps:get(<<"epoch">>,P)+case Revoke of true -> 1;false -> 0 end}.
changed(S,Routes) ->
    ok = ba_buffee_desks:configure(maps:get(buffee,S),maps:get(urls,S),maps:get(primary,S),maps:get(routes,S)),
    maps:foreach(fun(Peer,R) ->
        case Peer =:= maps:get(id,S) of true -> ok;false ->
            send(Peer,R,<<"policy">>,fresh(16),policy_state(S),S)
        end
    end,Routes),publish(S).
checkpoint_authority(#{role := member}=S) -> checkpoint_member(S);
checkpoint_authority(S) ->
    case maps:find(reusable_link,S) of
        {ok,Link} -> {_,Invitation}=ba_buffee_passport:parse_invitation(Link),
            ok=ba_buffee_desks:advertise(maps:get(<<"mailbox">>,maps:get(<<"route">>,Invitation)));
        error -> ok
    end,
    ok=save(buffee_authority,maps:with([policy,invitations,routes],S)),
    Snapshot=maps:with([policy,invitations,routes,name,urls,primary,reusable_link],S),
    Saved=#{name => maps:get(name,S),buffee => maps:get(buffee,S),
            config => #{mode => recover_authority,snapshot => Snapshot}},
    ok=save(buffee_connection,Saved),ba_buffee:remember_authority(self(),Saved),ok.
save(Name,Data) ->
    try ba_device_store:save(Name,Data)
    catch _:_ -> exit({membership_storage_failed,Name}) end.
view(S) -> #{device_roles => maps:from_list([{Id,ba_buffee_roles:roles(Id,maps:get(policy,S))} || Id <- maps:keys(maps:get(<<"members">>,maps:get(policy,S)))]),
              local_permissions => maps:get(<<"permissions">>,maps:get(maps:get(id,S),maps:get(<<"members">>,maps:get(policy,S)))),
              policy => ba_buffee_passport:runtime_policy(maps:get(policy,S),maps:get(id,S)),
              routes => maps:remove(maps:get(id,S),maps:get(routes,S)),until => infinity}.
publish(S) ->
    P=maps:get(policy,S),
    ba_contacts:observe(maps:get(buffee,S),maps:get(name,S),maps:keys(maps:remove(maps:get(id,S),maps:get(<<"members">>,P)))),
    notify({membership_authorized,view(S)}).
invalidate() -> notify(membership_invalidated).
notify(Event) -> case whereis(ba_buffee_control) of undefined -> ok;Pid -> Pid ! Event end.
send(To,R,Type,Request,Payload,S) ->
    Body = #{<<"v">> => 1,<<"type">> => Type,<<"from">> => maps:get(id,S),<<"to">> => To,
             <<"buffee">> => maps:get(buffee,S),<<"request">> => Request,<<"payload">> => Payload},
    ba_buffee_desks:send_route(To,R,<<"membership">>,sign(Body,S)).
sign(B,S) -> ba_buffee_passport:sign(B,maps:get(private,S)).
owner_present(#{policy := P,id := Self}) when is_map(P) ->
    lists:any(fun(Id) -> Id=:=Self orelse
        (try ba_buffee_desks:peer_online(Id) catch exit:_ -> false end) end,owners(P));
owner_present(_) -> false.
value(_,undefined) -> null;
value(K,P) -> maps:get(K,P).
fresh(N) -> binary:encode_hex(crypto:strong_rand_bytes(N)).
hex(B,N) -> ba_buffee_job:hex(B,N).
now_ms() -> erlang:monotonic_time(millisecond).
format_status(Status) -> maps:map(fun(state,S) -> maps:with([id,buffee,role,state],S);(log,_) -> [];(_,_) -> redacted end,Status).

invitations(Ids,_TTL,#{role := authority,invitations := Existing}=S)
        when is_list(Ids),length(Ids)>0,length(Ids)=<15 ->
    Live = Existing,
    case map_size(Live)+length(Ids)=<32 andalso
         lists:all(fun(Id) -> Id=:=undefined orelse hex(Id,64) end,Ids) of
        false -> {error,invalid_invitation};
        true ->
            {Link,Next}=case maps:find(reusable_link,S) of
              {ok,Shared} ->
                %% Explicitly inviting a selected contact can undo its removal;
                %% merely forwarding the same link does not clear that block.
                Invites=maps:map(fun(_,E) -> E#{blocked => maps:get(blocked,E,[])--Ids} end,Existing),
                {compact_link(Shared),S#{invitations := Invites}};
              error ->
                Id = fresh(16),Secret = fresh(32),
                I = #{<<"v">> => 1,<<"type">> => <<"invitation">>,<<"name">> => maps:get(name,S),
                    <<"buffee">> => maps:get(buffee,S),<<"authority">> => maps:get(id,S),
                    <<"invite">> => Id,<<"secret">> => Secret,<<"expires">> => null,
                    <<"desks">> => maps:get(urls,S),<<"route">> => maps:get(maps:get(id,S),maps:get(routes,S))},
                Entry = #{hash => crypto:hash(sha256,Secret),issuer => maps:get(id,S),blocked => []},
                Shared=ba_buffee_passport:invitation(sign(I,S)),
                {Shared,S#{reusable_link => Shared,invitations := Live#{Id => Entry}}}
            end,
            checkpoint_authority(Next),
            {ok,[#{device => Device,invitation => Link} || Device <- Ids],Next}
    end;
invitations(_,_,_) -> {error,owner_or_valid_invitation_required}.

compact_link(Link) ->
    {Packet,_}=ba_buffee_passport:parse_invitation(Link),
    ba_buffee_passport:invitation(Packet).

owners(undefined) -> [];
owners(P) -> [Id || Id <- maps:keys(maps:get(<<"members">>,P)),ba_buffee_roles:owner(Id,P)].
public_roles(#{policy := P,id := Id}) when is_map(P) -> ba_buffee_roles:roles(Id,P);
public_roles(_) -> [guest].
public_role(S) -> hd(public_roles(S)).
invitation_state(S) -> maps:map(fun(_,E) -> #{<<"hash">> => binary:encode_hex(maps:get(hash,E)),
    <<"issuer">> => maps:get(issuer,E,maps:get(id,S)),<<"blocked">> => maps:get(blocked,E,[])} end,maps:get(invitations,S)).
read_invitation_state(M) when is_map(M),map_size(M)=<32 -> maps:map(fun(_,E) ->
    ba_buffee_passport:exact(E,[<<"hash">>,<<"issuer">>,<<"blocked">>]),
    true=hex(maps:get(<<"hash">>,E),64),true=hex(maps:get(<<"issuer">>,E),64),
    Blocked=maps:get(<<"blocked">>,E),true=is_list(Blocked) andalso length(Blocked)=<16,
    true=lists:all(fun(D) -> hex(D,64) end,Blocked),
    #{hash => binary:decode_hex(maps:get(<<"hash">>,E)),issuer => maps:get(<<"issuer">>,E),blocked => Blocked}
end,M).

policy_state(#{role := authority,policy := P}=S) ->
    #{<<"signer">> => maps:get(id,S),<<"state">> => sign(owner_statement(P,S),S)};
policy_state(S) ->
    #{<<"signer">> => maps:get(policy_signer,S),<<"state">> => maps:get(signed_state,S)}.
owner_statement(P,S) -> #{<<"policy">> => P,<<"routes">> => maps:get(routes,S),
    <<"invitations">> => invitation_state(S)}.
announce(S) -> maps:foreach(fun(Peer,R) ->
    case Peer=:=maps:get(id,S) of true -> ok;false ->
        send(Peer,R,<<"presence">>,fresh(16),#{<<"route">> => ba_buffee_desks:route()},S)
    end
end,maps:get(routes,S)).

owned_update(P,S) ->
    Role=case ba_buffee_roles:owner(maps:get(id,S),P) of true -> authority;false -> member end,
    S#{policy := P,role := Role,policy_signer => maps:get(id,S),signed_state => sign(owner_statement(P,S),S)}.
checkpoint_member(#{policy := P,id := Id}=S) ->
    Owner=case owners(P) of [First|_] -> First;[] -> maps:get(authority,S) end,
    Route=maps:get(Owner,maps:get(routes,S),maps:get(authority_route,S,ba_buffee_desks:route())),
    Credential=case maps:find(credential,S) of
        {ok,Pass} -> Pass;
        error -> sign(#{<<"v">> => 1,<<"type">> => <<"passport">>,<<"buffee">> => maps:get(buffee,S),
            <<"authority">> => Id,<<"device">> => Id,<<"membership">> => maps:get(<<"membership">>,maps:get(Id,maps:get(<<"members">>,P))),
            <<"epoch">> => maps:get(<<"epoch">>,P)},S)
    end,
    %% The saved contact is only a reconnect hint; this carries no live session.
    Saved=#{id => Id,passport => Credential,authority => Owner,buffee => maps:get(buffee,S),
        desks => maps:get(urls,S),primary => maps:get(primary,S),authority_route => Route,
        floor => #{epoch => maps:get(<<"epoch">>,P),revision => maps:get(<<"revision">>,P)}},
    ok=save(buffee_member,Saved),ba_buffee:remember(self(),maps:get(name,S),Saved),ok.
