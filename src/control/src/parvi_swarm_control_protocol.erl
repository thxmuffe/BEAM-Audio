%% Pure, bounded application sessions. No OTP distribution, processes or device I/O.
-module(parvi_swarm_control_protocol).
-export([new/2, connect/3, request_status/3, request_capabilities/3, reply_capabilities/5,
         receive_packet/4, expire/2, reset/1,
         snapshot/1, seal/2,job_message/6,context/3,audio_message/5]).
-define(DOMAIN, <<"parvi-swarm-control/v1:">>).
-define(MAX, 32768).
-define(INT, 9007199254740991).

%% Policy is explicitly installed local configuration, not a peer-supplied grant.
new({Public, Private}, #{swarm := Swarm, authority := Authority,director := Director,epoch := Epoch,
                       revision := Revision, peers := Peers} = Policy) ->
    true = lists:sort(maps:keys(Policy)) =:= [authority,director,epoch,peers,revision,swarm],
    Id = binary:encode_hex(Public), true = hex(Id,64) andalso hex(Swarm,32),
    true = hex(Authority,64) andalso uint(Epoch) andalso Epoch > 0 andalso
           uint(Revision) andalso Revision > 0,
    true = is_map(Peers) andalso map_size(Peers) =< 32,
    true = Authority =:= Id orelse maps:is_key(Authority,Peers),
    true = hex(Director,64) andalso (Director =:= Id orelse maps:is_key(Director,Peers)),
    maps:foreach(fun(Peer, Permissions) ->
        true = hex(Peer,64) andalso Peer =/= Id,
        true = is_list(Permissions) andalso length(Permissions) =< 5,
        true = lists:usort(Permissions) =:= Permissions,
        true = lists:all(fun(P) -> lists:member(P,[status_read,capabilities_read,job_offer,stream_read,stream_subscribe]) end,Permissions)
    end,Peers),
    %% Reject an accidentally mismatched local key before opening a Desk route.
    Probe = crypto:sign(eddsa,none,?DOMAIN,[Private,ed25519]),
    true = crypto:verify(eddsa,none,?DOMAIN,Probe,[Public,ed25519]),
    #{id => Id, private => Private, policy => Policy, sessions => #{}}.

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

request_status(Peer, Now, S) ->
    request(Peer,status,<<"status.read">>,Now,S).
request_capabilities(Peer, Now, S) ->
    request(Peer,capabilities,<<"capabilities.read">>,Now,S).
request(Peer,Kind,Operation,Now,S) ->
    attempt(fun() ->
        Session = active(Peer,Now,S),
        false = maps:is_key(pending,Session),
        Request = fresh(16),
        {Packet,Next} = outgoing(Peer,Operation,Request,#{},
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
        #{peers := Peers,swarm := Swarm,authority := Authority,director := Director,
          epoch := Epoch,revision := Revision} = maps:get(policy,S),
        true = maps:is_key(From,Peers),
        Body = verify(Packet,From),
        #{<<"v">> := 1, <<"from">> := From, <<"to">> := To, <<"swarm">> := Swarm,
          <<"authority">> := Authority,<<"director">> := Director,
          <<"epoch">> := Epoch, <<"revision">> := Revision} = Body,
        To = maps:get(id,S),
        dispatch(From,Body,Now,S)
    end,S).

context(Peer,Now,S) ->
    Session = active(Peer,Now,S),
    #{swarm := Swarm,director := Director} = maps:get(policy,S),
    #{peer => Peer,session => maps:get(id,Session),deadline => maps:get(deadline,Session),
      swarm => Swarm,director => Director}.
job_message(Peer,Op,Id,Payload,Now,S) ->
    attempt(fun() ->
        true = hex(Id,32),
        true = lists:member(Op,[<<"job.offer">>,<<"job.cancel">>,<<"job.report">>]),
        case Op of
            <<"job.report">> -> ok;
            _ -> true = maps:get(id,S) =:= maps:get(director,maps:get(policy,S))
        end,
        payload(Op,Payload),
        {Packet,Next} = outgoing(Peer,Op,Id,Payload,active(Peer,Now,S),S),
        {ok,Packet,Next}
    end,S).

audio_message(Peer,Id,Payload,Now,S) ->
    attempt(fun() ->
        true = hex(Id,32),ok = parvi_audio_stream_protocol:validate(Payload),
        {Packet,Next} = outgoing(Peer,<<"stream.message">>,Id,Payload,active(Peer,Now,S),S),
        {ok,Packet,Next}
    end,S).

dispatch(Peer, #{<<"op">> := <<"hello">>,<<"seq">> := 0,<<"session">> := Id,
                 <<"request">> := Id,<<"payload">> := Payload}, Now, S) ->
    false = maps:is_key(Peer,maps:get(sessions,S)),
    #{<<"a">> := A,<<"b">> := null} = Payload,
    Session = #{id => Id,a => A,b => fresh(32),stage => challenge,
                deadline => Now+10000,sent => 0,received => 0},
    {Packet,Next} = outgoing(Peer,<<"challenge">>,Id,nonces(Session),Session,S),
    {ok,[Packet],[],Next};
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
            {<<"ready">>,Session#{stage := authorized,deadline := min(Now+60000,maps:get(membership_deadline,S,infinity))}};
        {<<"ready">>,proof} ->
            Payload = nonces(Session),
            {none,Session#{stage := authorized,deadline := min(Now+60000,maps:get(membership_deadline,S,infinity))}}
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
            true = Peer =:= maps:get(director,Policy),
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
                    {ok,[],[{capabilities_read,Request}],put(Peer,Received#{capability_request => Request},S)};
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
                    false -> {Acc#{Peer => Session},Es}
                end
        end
    end,{#{},[]},Sessions),
    {Events,S#{sessions := Kept}}.
reset(S) -> S#{sessions := #{}}.
snapshot(S) ->
    #{id => maps:get(id,S),sessions => maps:map(fun(_,V) ->
        maps:with([stage],V) end,maps:get(sessions,S))}.

outgoing(Peer, Op, Request, Payload, Session, S) ->
    #{swarm := Swarm,authority := Authority,director := Director,epoch := Epoch,revision := Revision} = maps:get(policy,S),
    Sequence = case maps:get(stage,Session) of
        authorized when Op =/= <<"ready">> -> maps:get(sent,Session)+1;
        _ -> 0
    end,
    true = uint(Sequence),
    Body = #{<<"v">> => 1,<<"from">> => maps:get(id,S),<<"to">> => Peer,
        <<"swarm">> => Swarm,<<"authority">> => Authority,<<"director">> => Director,
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
    exact(Body,[<<"v">>,<<"from">>,<<"to">>,<<"swarm">>,<<"authority">>,<<"director">>,<<"epoch">>,<<"revision">>,
                <<"session">>,<<"seq">>,<<"op">>,<<"request">>,<<"payload">>]),
    [true = hex(maps:get(K,Body),N) || {K,N} <-
        [{<<"from">>,64},{<<"to">>,64},{<<"authority">>,64},{<<"director">>,64},{<<"swarm">>,32},
         {<<"session">>,32},{<<"request">>,32}]],
    [true = uint(maps:get(K,Body)) || K <- [<<"seq">>,<<"epoch">>,<<"revision">>]],
    payload(maps:get(<<"op">>,Body),maps:get(<<"payload">>,Body)), Body.

payload(Op,P) when Op =:= <<"hello">>; Op =:= <<"challenge">>;
                   Op =:= <<"proof">>; Op =:= <<"ready">> ->
    exact(P,[<<"a">>,<<"b">>]), true = hex(maps:get(<<"a">>,P),64),
    B = maps:get(<<"b">>,P), true = B =:= null orelse hex(B,64);
payload(<<"status.read">>,P) -> exact(P,[]);
payload(<<"status.reply">>,P) ->
    exact(P,[<<"protocol">>,<<"session">>]),
    #{<<"protocol">> := 1,<<"session">> := <<"authorized">>} = P;
payload(<<"status.error">>,P) ->
    exact(P,[<<"reason">>]), #{<<"reason">> := <<"forbidden">>} = P;
payload(<<"capabilities.read">>,P) -> exact(P,[]);
payload(<<"capabilities.reply">>,P) -> capability_payload(P);
payload(<<"capabilities.error">>,P) ->
    exact(P,[<<"reason">>]),
    Reason = maps:get(<<"reason">>,P),
    true = Reason =:= <<"forbidden">> orelse Reason =:= <<"unavailable">>;
payload(<<"stream.message">>,P) -> parvi_audio_stream_protocol:validate(P);
payload(<<"job.offer">>,P) -> parvi_swarm_job:validate_offer(P);
payload(<<"job.cancel">>,P) -> exact(P,[]);
payload(<<"job.report">>,P) -> parvi_swarm_job:validate_report(P);
payload(_,_) -> throw(forbidden_operation).

capability_payload(P) ->
    exact(P,[<<"instance">>,<<"revision">>,<<"test">>]),
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
        object_start => fun({Depth,_}) -> true = Depth < 3, {Depth+1,#{}} end,
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
