%% Pure, bounded application sessions. No OTP distribution, processes or device I/O.
-module(ba_buffee_control_protocol).
-export([new/2, connect/3, request_status/3, request_capabilities/3,request_capabilities/4, reply_capabilities/5,chat_message/5,
         receive_packet/4, expire/2, reset/1,
         snapshot/1, seal/2,renew/3,renew_due/2,job_message/6,context/3,audio_message/5,time_message/5]).
-define(DOMAIN, <<"beamaudio-buffee-control/v1:">>).
-define(MAX, 32768).
-define(INT, 9007199254740991).

%% Policy is explicitly installed local configuration, not a peer-supplied grant.
new({Public, Private}, #{buffee := Buffee, authority := Authority,manager := Manager,epoch := Epoch,
                       revision := Revision, peers := Peers} = Policy) ->
    true = lists:sort(maps:keys(Policy)) =:= [authority,buffee,epoch,manager,peers,revision],
    Id = binary:encode_hex(Public), true = hex(Id,64) andalso hex(Buffee,32),
    true = hex(Authority,64) andalso uint(Epoch) andalso Epoch > 0 andalso
           uint(Revision) andalso Revision > 0,
    true = is_map(Peers) andalso map_size(Peers) =< 32,
    %% Reference identities need not be online members.

    true = hex(Manager,64),
    maps:foreach(fun(Peer, Permissions) ->
        true = hex(Peer,64) andalso Peer =/= Id,
        true = is_list(Permissions) andalso length(Permissions) =< 9,
        true = lists:usort(Permissions) =:= Permissions,
        true = lists:all(fun(P) -> lists:member(P,[status_read,capabilities_read,job_offer,stream_read,stream_subscribe,time_read,offset_write,owner,stream_publish]) end,Permissions)
    end,Peers),
    %% Reject an accidentally mismatched local key before opening a Desk route.
    Probe = crypto:sign(eddsa,none,?DOMAIN,[Private,ed25519]),
    true = crypto:verify(eddsa,none,?DOMAIN,Probe,[Public,ed25519]),
    #{id => Id, private => Private, policy => Policy, sessions => #{},rekeys => #{}}.

connect(Peer, Now, S) ->
    attempt(fun() ->
        true = Now < maps:get(membership_deadline,S,infinity),
        true = maps:is_key(Peer,maps:get(peers,maps:get(policy,S))),
        false = maps:is_key(Peer,maps:get(sessions,S)),
        Session = #{id => fresh(16), a => fresh(32), b => null, stage => hello,
                    deadline => Now+10000, sent => 0, received => 0},
        {Packet,Next} = outgoing(Peer,<<"hello">>,maps:get(id,Session),
                                 nonces(Session),Session,S),
        {ok,Packet,Next}
    end,S).

%% Stable session/replay sequence, fresh two-way nonce proof for each lease.
%% One deterministic initiator avoids simultaneous renewals.
renew_due(Now,S) ->
    [Peer || {Peer,#{stage := authorized}=Session} <- maps:to_list(maps:get(sessions,S)),
        maps:get(id,S)<Peer,Now>=maps:get(renew_after,Session,infinity),
        not maps:is_key(renewal,Session),Now<maps:get(deadline,Session)].
renew(Peer,Now,S) ->
    attempt(fun() ->
        Session = active(Peer,Now,S),false = maps:is_key(renewal,Session),
        R = #{id => fresh(16),a => fresh(32),b => null,stage => request,deadline => Now+5000},
        {Packet,Next} = outgoing(Peer,<<"lease.request">>,maps:get(id,R),nonces(R),Session#{renewal => R},S),
        {ok,Packet,Next}
    end,S).
lease_ms(S) -> maps:get(lease_ms,S,60000).
extend(Session,Now,S) ->
    (maps:remove(renewal,Session))#{deadline := min(Now+lease_ms(S),maps:get(membership_deadline,S,infinity)),
        renew_after => Now+lease_ms(S) div 3,renewals => maps:get(renewals,Session,0)+1}.

request_status(Peer, Now, S) ->
    request(Peer,status,<<"status.read">>,Now,S).
request_capabilities(Peer, Now, S) ->
    request(Peer,capabilities,<<"capabilities.read">>,Now,S).
request_capabilities(Peer,true,Now,S) -> request(Peer,capabilities,<<"capabilities.read">>,#{<<"metrics">> => true},Now,S);
request_capabilities(Peer,false,Now,S) -> request_capabilities(Peer,Now,S).
request(Peer,Kind,Operation,Now,S) -> request(Peer,Kind,Operation,#{},Now,S).
request(Peer,Kind,Operation,Payload,Now,S) ->
    attempt(fun() ->
        Session = active(Peer,Now,S),
        false = maps:is_key(pending,Session),
        Request = fresh(16),
        {Packet,Next} = outgoing(Peer,Operation,Request,Payload,
            Session#{pending => Request,pending_kind => Kind,request_deadline => Now+5000},S),
        {ok,Packet,Next}
    end,S).

%% Only the local adapter supplies capability data, after verified dispatch.
reply_capabilities(Peer,Request,Value,Now,S) ->
    attempt(fun() ->
        #{capability_request := Request} = Session = active(Peer,Now,S),
        {Op,Payload} = case Value of
            unavailable -> {<<"capabilities.error">>,#{<<"reason">> => <<"unavailable">>}};
            _ -> capability_payload(Value), {<<"capabilities.reply">>,Value}
        end,
        {Packet,Next} = outgoing(Peer,Op,Request,Payload,maps:remove(capability_request,Session),S),
        {ok,Packet,Next}
    end,S).

receive_packet(From, Packet, Now, S) ->
    attempt(fun() ->
        true = Now < maps:get(membership_deadline,S,infinity),
        #{peers := Peers,buffee := Buffee,authority := Authority,manager := Manager,
          epoch := Epoch,revision := Revision} = maps:get(policy,S),
        true = maps:is_key(From,Peers),
        Body = verify(Packet,From),
        #{<<"v">> := 1, <<"from">> := From, <<"to">> := To, <<"buffee">> := Buffee,
          <<"authority">> := Authority,<<"manager">> := Manager,
          <<"epoch">> := Epoch, <<"revision">> := Revision} = Body,
        To = maps:get(id,S),
        dispatch(From,Body,Now,S)
    end,S).

context(Peer,Now,S) ->
    Session = active(Peer,Now,S),
    #{buffee := Buffee,manager := Manager} = maps:get(policy,S),
    #{peer => Peer,session => maps:get(id,Session),deadline => maps:get(deadline,Session),
      buffee => Buffee,manager => Manager}.
job_message(Peer,Op,Id,Payload,Now,S) ->
    attempt(fun() ->
        true = hex(Id,32),
        true = lists:member(Op,[<<"job.offer">>,<<"job.cancel">>,<<"job.report">>]),
        payload(Op,Payload),
        {Packet,Next} = outgoing(Peer,Op,Id,Payload,active(Peer,Now,S),S),
        {ok,Packet,Next}
    end,S).

chat_message(Peer,Id,Text,Now,S) ->
    attempt(fun() ->
        true=hex(Id,32),Payload=#{<<"text">> => Text},payload(<<"chat.message">>,Payload),
        {Packet,Next}=outgoing(Peer,<<"chat.message">>,Id,Payload,active(Peer,Now,S),S),{ok,Packet,Next}
    end,S).

audio_message(Peer,Id,Payload,Now,S) ->
    attempt(fun() ->
        true = hex(Id,32),ok = ba_audio_stream_protocol:validate(Payload),
        {Packet,Next} = outgoing(Peer,<<"stream.message">>,Id,Payload,active(Peer,Now,S),S),
        {ok,Packet,Next}
    end,S).

time_message(Peer,Id,Payload,Now,S) ->
    attempt(fun() ->
        true = hex(Id,32),ok = ba_buffee_time_protocol:validate(Payload),
        {Packet,Next} = outgoing(Peer,<<"time.message">>,Id,Payload,active(Peer,Now,S),S),
        {ok,Packet,Next}
    end,S).

%% A fresh proof may replace a surviving remote session after a local owner restart.
%% A replayed hello only prepares a challenge; it cannot tear down active work.
dispatch(Peer,#{<<"op">> := <<"proof">>,<<"session">> := Id}=Body,Now,#{rekeys := Rekeys}=S)
        when is_map_key(Peer,Rekeys) ->
    #{id := Id}=Candidate = maps:get(Peer,Rekeys),
    Sessions = maps:get(sessions,S),
    Events = case maps:find(Peer,Sessions) of {ok,#{id := Old}} -> [{session_replaced,Old}];error -> [] end,
    Temp = S#{rekeys := maps:remove(Peer,Rekeys),sessions := Sessions#{Peer => Candidate}},
    {ok,Packets,More,Next} = dispatch(Peer,Body,Now,Temp),
    {ok,Packets,Events++More,Next};
dispatch(Peer, #{<<"op">> := <<"hello">>,<<"seq">> := 0,<<"session">> := Id,
                 <<"request">> := Id,<<"payload">> := Payload}, Now, S) ->
    Sessions = maps:get(sessions,S),
    case maps:find(Peer,Sessions) of
        error -> ok;
        {ok,#{stage := authorized,id := Old}} -> true = Id=/=Old
    end,
    #{<<"a">> := A,<<"b">> := null} = Payload,
    Session = #{id => Id,a => A,b => fresh(32),stage => challenge,
                deadline => Now+10000,sent => 0,received => 0},
    {Packet,Next} = outgoing(Peer,<<"challenge">>,Id,nonces(Session),Session,S),
    case maps:is_key(Peer,Sessions) of
        false -> {ok,[Packet],[],Next#{rekeys => maps:remove(Peer,maps:get(rekeys,S,#{}))}};
        true ->
            Rekeys = maps:get(rekeys,S,#{}),
            {ok,[Packet],[],Next#{sessions := Sessions,rekeys => Rekeys#{Peer => Session}}}
    end;
dispatch(Peer, #{<<"op">> := Op,<<"seq">> := 0,<<"session">> := Id,
                 <<"request">> := Id,<<"payload">> := Payload}, Now, S)
        when Op =:= <<"challenge">>; Op =:= <<"proof">>; Op =:= <<"ready">> ->
    #{id := Id,deadline := Deadline} = Session = maps:get(Peer,maps:get(sessions,S)),
    true = Now < Deadline,
    {Reply,Updated} = case {Op,maps:get(stage,Session)} of
        {<<"challenge">>,hello} ->
            #{<<"a">> := A,<<"b">> := B} = Payload,
            A = maps:get(a,Session), true = hex(B,64),
            {<<"proof">>,Session#{b := B,stage := proof}};
        {<<"proof">>,challenge} ->
            Payload = nonces(Session),
            {<<"ready">>,Session#{stage := authorized,deadline := min(Now+lease_ms(S),maps:get(membership_deadline,S,infinity)),renew_after => Now+lease_ms(S) div 3}};
        {<<"ready">>,proof} ->
            Payload = nonces(Session),
            {none,Session#{stage := authorized,deadline := min(Now+lease_ms(S),maps:get(membership_deadline,S,infinity)),renew_after => Now+lease_ms(S) div 3}}
    end,
    case Reply of
        none -> {ok,[],[authorized],put(Peer,Updated,S)};
        _ ->
            {Packet,Next} = outgoing(Peer,Reply,Id,nonces(Updated),Updated,S),
            {ok,[Packet],[],Next}
    end;
dispatch(Peer, #{<<"op">> := Op,<<"seq">> := Sequence,<<"session">> := Id,
                 <<"request">> := Request,<<"payload">> := Payload}, Now, S) ->
    #{id := Id,received := Last} = Session = active(Peer,Now,S),
    true = Sequence > Last,
    Received = Session#{received := Sequence},
    case Op of
        <<"chat.message">> ->
            {ok,[],[{chat,Request,maps:get(<<"text">>,Payload),context(Peer,Now,put(Peer,Received,S))}],put(Peer,Received,S)};
        _ when Op=:= <<"lease.request">>;Op=:= <<"lease.challenge">>;
               Op=:= <<"lease.proof">>;Op=:= <<"lease.ready">> ->
            lease(Peer,Op,Request,Payload,Received,Now,S);
        <<"time.message">> ->
            Grant = ba_buffee_time_protocol:permission(maps:get(<<"kind">>,Payload)),
            Permissions = maps:get(Peer,maps:get(peers,maps:get(policy,S))),
            Allowed=case maps:get(<<"kind">>,Payload) of
                <<"offset.set">> -> ba_buffee_roles:can_edit_settings([atom_to_binary(P) || P <- Permissions]);
                _ -> Grant=:=none orelse lists:member(Grant,Permissions) end,
            case Allowed of
                true -> {ok,[],[{time,Request,Payload,context(Peer,Now,S)}],put(Peer,Received,S)};
                false ->
                    Error = #{<<"kind">> => <<"error">>,<<"operation">> => maps:get(<<"kind">>,Payload),<<"reason">> => <<"forbidden">>},
                    {Packet,Next} = outgoing(Peer,<<"time.message">>,Request,Error,Received,S),
                    {ok,[Packet],[],Next}
            end;
        <<"stream.message">> ->
            Permissions = maps:get(Peer,maps:get(peers,maps:get(policy,S))),
            case maps:get(<<"kind">>,Payload) of
                <<"catalog.read">> -> true = lists:member(stream_read,Permissions);
                <<"subscribe">> -> true = lists:member(stream_subscribe,Permissions);
                _ -> ok
            end,
            {ok,[],[{audio,Request,Payload,context(Peer,Now,S)}],put(Peer,Received,S)};
        _ when Op =:= <<"job.offer">>; Op =:= <<"job.cancel">> ->
            Policy = maps:get(policy,S),
            true = lists:member(job_offer,maps:get(Peer,maps:get(peers,Policy))),
            {ok,[],[{job,Op,Request,Payload,context(Peer,Now,S)}],put(Peer,Received,S)};
        <<"job.report">> ->
            {ok,[],[{job_report,Request,Payload,context(Peer,Now,S)}],put(Peer,Received,S)};
        <<"status.read">> ->
            Permissions = maps:get(Peer,maps:get(peers,maps:get(policy,S))),
            {Reply,Value} = case lists:member(status_read,Permissions) of
                true -> {<<"status.reply">>,#{<<"protocol">> => 1,<<"session">> => <<"authorized">>}};
                false -> {<<"status.error">>,#{<<"reason">> => <<"forbidden">>}}
            end,
            {Packet,Next} = outgoing(Peer,Reply,Request,Value,Received,S),
            {ok,[Packet],[],Next};
        <<"capabilities.read">> ->
            Permissions = maps:get(Peer,maps:get(peers,maps:get(policy,S))),
            case lists:member(capabilities_read,Permissions) of
                true ->
                    false = maps:is_key(capability_request,Session),
                    Event=case maps:get(<<"metrics">>,Payload,false) of true -> {capabilities_read,Request,true};false -> {capabilities_read,Request} end,
                    {ok,[],[Event],put(Peer,Received#{capability_request => Request},S)};
                false ->
                    {Packet,Next} = outgoing(Peer,<<"capabilities.error">>,Request,
                        #{<<"reason">> => <<"forbidden">>},Received,S),
                    {ok,[Packet],[],Next}
            end;
        _ when Op =:= <<"status.reply">>; Op =:= <<"status.error">>;
               Op =:= <<"capabilities.reply">>; Op =:= <<"capabilities.error">> ->
            Request = maps:get(pending,Session),
            Kind = case Op of
                <<"status.",_/binary>> -> status;
                _ -> capabilities
            end,
            Kind = maps:get(pending_kind,Session),
            true = Now < maps:get(request_deadline,Session),
            Next = put(Peer,maps:without([pending,pending_kind,request_deadline],Received),S),
            {ok,[],[{reply,Op,Payload}],Next}
    end.

lease(Peer,<<"lease.request">>,Id,#{<<"a">> := A,<<"b">> := null},Session,Now,S) ->
    %% One bounded exchange per renewal interval, even for an authenticated peer.
    %% Critical local renewal notifications cannot become a per-packet flood.
    false = maps:is_key(renewal,Session),
    true = Now+min(1000,lease_ms(S) div 6)>=maps:get(renew_after,Session),
    R = #{id => Id,a => A,b => fresh(32),stage => challenge,deadline => Now+5000},
    {Packet,Next} = outgoing(Peer,<<"lease.challenge">>,Id,nonces(R),Session#{renewal => R},S),
    {ok,[Packet],[],Next};
lease(Peer,Op,Id,Payload,Session,Now,S) ->
    #{id := Id,deadline := Until}=R = maps:get(renewal,Session),true = Now<Until,
    case {Op,maps:get(stage,R)} of
        {<<"lease.challenge">>,request} ->
            #{<<"a">> := A,<<"b">> := B} = Payload,A = maps:get(a,R),true = hex(B,64),
            NextR = R#{b := B,stage := proof},
            {Packet,Next} = outgoing(Peer,<<"lease.proof">>,Id,nonces(NextR),Session#{renewal := NextR},S),
            {ok,[Packet],[],Next};
        {<<"lease.proof">>,challenge} ->
            Payload = nonces(R),Updated = extend(Session,Now,S),
            {Packet,Next} = outgoing(Peer,<<"lease.ready">>,Id,Payload,Updated,S),
            {ok,[Packet],[{session_renewed,context(Peer,Now,Next)}],Next};
        {<<"lease.ready">>,proof} ->
            Payload = nonces(R),Next = put(Peer,extend(Session,Now,S),S),
            {ok,[],[{session_renewed,context(Peer,Now,Next)}],Next}
    end.

active(Peer, Now, S) ->
    #{stage := authorized,deadline := Deadline} = Session = maps:get(Peer,maps:get(sessions,S)),
    true = Now < Deadline,true = Now < maps:get(membership_deadline,S,infinity), Session.

%% Expiry is also checked synchronously on every receive/request, never just by a timer.
expire(Now, #{sessions := Sessions} = S) ->
    {Kept,Events} = maps:fold(fun(Peer,Session,{Acc,Es}) ->
        case Now >= maps:get(deadline,Session) of
            true -> {Acc,[{Peer,session_expired}|Es]};
            false ->
                case maps:get(request_deadline,Session,infinity) =< Now of
                    true -> {Acc#{Peer => maps:without([pending,pending_kind,request_deadline],Session)},
                             [{Peer,request_timeout}|Es]};
                    false ->
                        Live = case maps:get(renewal,Session,undefined) of
                            #{deadline := Due} when Now>=Due -> maps:remove(renewal,Session#{renew_after => Now+1000});
                            _ -> Session
                        end,
                        {Acc#{Peer => Live},Es}
                end
        end
    end,{#{},[]},Sessions),
    Rekeys = maps:filter(fun(_,R) -> maps:get(deadline,R)>Now end,maps:get(rekeys,S,#{})),
    {Events,S#{sessions := Kept,rekeys => Rekeys}}.
reset(S) -> S#{sessions := #{},rekeys => #{}}.
snapshot(S) ->
    #{id => maps:get(id,S),sessions => maps:map(fun(_,V) ->
        maps:with([stage,deadline,renewals],V) end,maps:get(sessions,S))}.

outgoing(Peer, Op, Request, Payload, Session, S) ->
    #{buffee := Buffee,authority := Authority,manager := Manager,epoch := Epoch,revision := Revision} = maps:get(policy,S),
    Sequence = case maps:get(stage,Session) of
        authorized when Op =/= <<"ready">> -> maps:get(sent,Session)+1;
        _ -> 0
    end,
    true = uint(Sequence),
    Body = #{<<"v">> => 1,<<"from">> => maps:get(id,S),<<"to">> => Peer,
        <<"buffee">> => Buffee,<<"authority">> => Authority,<<"manager">> => Manager,
        <<"epoch">> => Epoch,<<"revision">> => Revision,
        <<"session">> => maps:get(id,Session),<<"seq">> => Sequence,
        <<"op">> => Op,<<"request">> => Request,<<"payload">> => Payload},
    {seal(Body,maps:get(private,S)),put(Peer,Session#{sent := Sequence},S)}.

%% Exact body bytes are signed, with no term decoding, canonicalization or atom creation.
seal(Body, Private) ->
    Data = iolist_to_binary(json:encode(Body)),
    Signature = crypto:sign(eddsa,none,[?DOMAIN,Data],[Private,ed25519]),
    Packet = iolist_to_binary(json:encode(#{<<"body">> => base64:encode(Data),
                                          <<"signature">> => binary:encode_hex(Signature)})),
    true = byte_size(Packet) =< ?MAX, Packet.
verify(Packet, From) when is_binary(Packet), byte_size(Packet) =< ?MAX ->
    Envelope = decode(Packet), exact(Envelope,[<<"body">>,<<"signature">>]),
    Encoded = maps:get(<<"body">>,Envelope), true = is_binary(Encoded),
    Sig = maps:get(<<"signature">>,Envelope), true = hex(Sig,128),
    Data = base64:decode(Encoded),
    true = crypto:verify(eddsa,none,[?DOMAIN,Data],binary:decode_hex(Sig),
                         [binary:decode_hex(From),ed25519]),
    Body = decode(Data),
    exact(Body,[<<"v">>,<<"from">>,<<"to">>,<<"buffee">>,<<"authority">>,<<"manager">>,<<"epoch">>,<<"revision">>,
                <<"session">>,<<"seq">>,<<"op">>,<<"request">>,<<"payload">>]),
    [true = hex(maps:get(K,Body),N) || {K,N} <-
        [{<<"from">>,64},{<<"to">>,64},{<<"authority">>,64},{<<"manager">>,64},{<<"buffee">>,32},
         {<<"session">>,32},{<<"request">>,32}]],
    [true = uint(maps:get(K,Body)) || K <- [<<"seq">>,<<"epoch">>,<<"revision">>]],
    payload(maps:get(<<"op">>,Body),maps:get(<<"payload">>,Body)), Body.

payload(Op,P) when Op =:= <<"hello">>; Op =:= <<"challenge">>;
                   Op =:= <<"proof">>; Op =:= <<"ready">>;
                   Op =:= <<"lease.request">>;Op =:= <<"lease.challenge">>;
                   Op =:= <<"lease.proof">>;Op =:= <<"lease.ready">> ->
    exact(P,[<<"a">>,<<"b">>]), true = hex(maps:get(<<"a">>,P),64),
    B = maps:get(<<"b">>,P), true = B =:= null orelse hex(B,64);
payload(<<"chat.message">>,P) ->
    exact(P,[<<"text">>]),Text=maps:get(<<"text">>,P),
    true=is_binary(Text) andalso byte_size(Text)>0 andalso byte_size(Text)=<4096,
    true=is_list(unicode:characters_to_list(Text));
payload(<<"status.read">>,P) -> exact(P,[]);
payload(<<"status.reply">>,P) ->
    exact(P,[<<"protocol">>,<<"session">>]),
    #{<<"protocol">> := 1,<<"session">> := <<"authorized">>} = P;
payload(<<"status.error">>,P) ->
    exact(P,[<<"reason">>]), #{<<"reason">> := <<"forbidden">>} = P;
payload(<<"capabilities.read">>,#{<<"metrics">> := true}=P) -> exact(P,[<<"metrics">>]);
payload(<<"capabilities.read">>,P) -> exact(P,[]);
payload(<<"capabilities.reply">>,P) -> capability_payload(P);
payload(<<"capabilities.error">>,P) ->
    exact(P,[<<"reason">>]),
    Reason = maps:get(<<"reason">>,P),
    true = Reason =:= <<"forbidden">> orelse Reason =:= <<"unavailable">>;
payload(<<"time.message">>,P) -> ba_buffee_time_protocol:validate(P);
payload(<<"stream.message">>,P) -> ba_audio_stream_protocol:validate(P);
payload(<<"job.offer">>,P) -> ba_buffee_job:validate_offer(P);
payload(<<"job.cancel">>,P) -> exact(P,[]);
payload(<<"job.report">>,P) -> ba_buffee_job:validate_report(P);
payload(_,_) -> throw(forbidden_operation).

capability_payload(P) ->
    exact(P,[<<"instance">>,<<"revision">>,<<"test">>]++[K || K <- [<<"audio">>,<<"device_name">>,<<"audio_diagnostics">>],maps:is_key(K,P)]),
    case maps:find(<<"audio_diagnostics">>,P) of error -> ok;{ok,D} -> ba_audio_diagnostics:validate(D) end,
    case maps:find(<<"device_name">>,P) of
        error -> ok;
        {ok,Name} -> true=is_binary(Name) andalso byte_size(Name)>0 andalso byte_size(Name)=<256,
            true=is_list(unicode:characters_to_list(Name))
    end,
    case maps:find(<<"audio">>,P) of
        {ok,Audio} ->
            exact(Audio,[<<"speaker">>,<<"microphone">>,<<"broadcast">>]),
            maps:foreach(fun(_,Entry) ->
                Extra=[<<"error">>,<<"peak_db">>,<<"rms_db">>,<<"meter_age_ms">>,<<"meter_stage">>,<<"blocks">>,<<"frames">>,<<"dropped">>],
                exact(Entry,[<<"consent">>,<<"state">>,<<"available">>]++[K || K <- Extra,maps:is_key(K,Entry)]),
                [begin V=maps:get(K,Entry),true=is_number(V) andalso V>= -96 andalso V=<48 end || K <- [<<"peak_db">>,<<"rms_db">>],maps:is_key(K,Entry)],
                [true=uint(maps:get(K,Entry)) || K <- [<<"meter_age_ms">>,<<"blocks">>,<<"frames">>,<<"dropped">>],maps:is_key(K,Entry)],
                case maps:find(<<"meter_stage">>,Entry) of error -> ok;{ok,Stage} -> true=lists:member(Stage,[<<"capture">>,<<"receive_max">>]) end,
                case maps:find(<<"error">>,Entry) of
                    error -> ok;
                    {ok,Error} -> true=is_binary(Error) andalso byte_size(Error)=<256,
                        true=is_list(unicode:characters_to_list(Error))
                end,
                true=is_boolean(maps:get(<<"consent">>,Entry)),true=is_boolean(maps:get(<<"available">>,Entry)),
                State=maps:get(<<"state">>,Entry),true=is_binary(State) andalso byte_size(State)=<64
            end,Audio);
        error -> ok
    end,
    true = hex(maps:get(<<"instance">>,P),32),true = uint(maps:get(<<"revision">>,P)),
    Test = maps:get(<<"test">>,P),
    exact(Test,[<<"supported">>,<<"available">>,<<"requires_consent">>,<<"consent">>,
                <<"capacity">>,<<"active">>,<<"max_duration_ms">>]),
    #{<<"supported">> := true,<<"requires_consent">> := true,
      <<"capacity">> := 2,<<"max_duration_ms">> := 10000} = Test,
    true = is_boolean(maps:get(<<"available">>,Test)),
    true = is_boolean(maps:get(<<"consent">>,Test)),
    Active = maps:get(<<"active">>,Test), true = is_integer(Active) andalso Active >= 0 andalso Active =< 2.

%% Reject duplicate keys, arrays, excess nesting and oversized number strings.
decode(Data) ->
    {Value,_,<<>>} = json:decode(Data,{0,#{}},#{
        object_start => fun({Depth,_}) -> true = Depth < 5, {Depth+1,#{}} end,
        object_push => fun(K,V,{D,M}) -> false = maps:is_key(K,M), {D,M#{K => V}} end,
        object_finish => fun({_,M},Old) -> {M,Old} end,
        array_start => fun(_) -> error(arrays_not_allowed) end,
        integer => fun(B) -> true = byte_size(B) =< 16, binary_to_integer(B) end}), Value.
exact(M,Keys) -> true = is_map(M), true = lists:sort(maps:keys(M)) =:= lists:sort(Keys).
uint(N) -> is_integer(N) andalso N >= 0 andalso N =< ?INT.
hex(B,N) when is_binary(B), byte_size(B) =:= N ->
    re:run(B,<<"^[0-9A-F]+$">>,[{capture,none}]) =:= match;
hex(_,_) -> false.
fresh(N) -> binary:encode_hex(crypto:strong_rand_bytes(N)).
nonces(#{a := A,b := B}) -> #{<<"a">> => A,<<"b">> => B}.
put(Peer,Session,#{sessions := Sessions} = S) -> S#{sessions := Sessions#{Peer => Session}}.
attempt(Fun,S) ->
    try Fun() catch
        throw:forbidden_operation -> {error,forbidden_operation,S};
        _:_ -> {error,invalid_or_unauthorized,S}
    end.
