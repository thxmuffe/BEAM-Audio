%% Pure, bounded control messages. No OTP distribution, processes or device I/O.
%%
%% Every packet authenticates itself: the sender signs the exact body, which
%% names the recipient and Link, carries the sender's join certificate (signed
%% by the invitation key), the sender's instance (one per protocol state), a
%% rising sequence number and the sender's wall-clock time. Nobody keeps a list
%% of who is in the Link; any Device with a valid join certificate that has
%% not been removed may ask, and its rights come from the signed statement. There is no handshake and no background renewal: a Device verifies each
%% request when it arrives, and ba_device_request decides it. A relationship
%% with a peer exists while its packets keep arriving and lapses when idle.
-module(ba_session_control_protocol).
-export([new/3, connect/3, request_status/3, request_capabilities/3,request_capabilities/4, reply_capabilities/5,chat_message/5,
         receive_packet/4, expire/2, reset/2, close/3, set_policy/2, peer_revision/2,
         snapshot/1, seal/2,context/3,audio_message/5,session_message/5,request_inspection/4,reply_inspection/5]).
-define(DOMAIN, <<"beamaudio-session-control/v1:">>).
-define(VERSION, 3).
%% Sealing (ba_session_passport:seal_envelope) adds a third; Reception allows 32768.
-define(MAX, 24000).
-define(INT, 9007199254740991).
%% Accepted difference between sender and receiver wall clocks.
-define(SKEW, 300000).
%% In-flight packets sent just before this state started are still accepted.
-define(START_SLACK, 2000).
%% Retired sender instances remembered per peer.
-define(RETIRED, 4).

%% Policy is this Device's current signed rights statement, resolved locally:
%% members' rights, defaults for everyone else, removed Devices, the public
%% invitation key and this Device's own join certificate.
new({Public, Private}, Policy, Now) ->
    Id = binary:encode_hex(Public), true = ba_hex:valid(Id,64),
    %% Reject an accidentally mismatched local key before opening a Desk route.
    Probe = crypto:sign(eddsa,none,?DOMAIN,[Private,ed25519]),
    true = crypto:verify(eddsa,none,?DOMAIN,Probe,[Public,ed25519]),
    set_policy(Policy,reset(#{id => Id, private => Private},Now)).

%% Rights change without restarting relationships: every request is checked
%% against the statement in force when it arrives.
set_policy(#{session := Session,authority := Authority,manager := Manager,revision := Revision,
             invitation := Invitation,join := Join,members := Members,defaults := Defaults,
             removed := Removed} = Policy,#{id := Id} = S) ->
    true = ba_hex:valid(Session,32) andalso ba_hex:valid(Authority,64) andalso ba_hex:valid(Manager,64) andalso ba_hex:valid(Invitation,64),
    true = uint(Revision) andalso Revision > 0,
    true = ba_session_passport:joined(Session,Id,Join,Invitation),
    true = is_map(Members) andalso map_size(Members) =< 16,
    maps:foreach(fun(Peer,Rights) -> true = ba_hex:valid(Peer,64),rights(Rights) end,Members),
    rights(Defaults),
    true = is_list(Removed) andalso length(Removed) =< 31 andalso lists:all(fun(R) -> ba_hex:valid(R,64) end,Removed),
    S#{policy => Policy}.
rights(Rights) ->
    true = is_list(Rights) andalso length(Rights) =< 10 andalso lists:usort(Rights) =:= Rights,
    true = lists:all(fun(P) -> lists:member(P,[status_read,capabilities_read,stream_read,stream_subscribe,
        owner,stream_publish,end_session]) end,Rights).
held(Peer,S) -> #{members := Members,defaults := Defaults} = maps:get(policy,S),maps:get(Peer,Members,Defaults).
%% The rights-statement revision the peer last sent, so the newer side can share.
peer_revision(Peer,S) -> maps:get(revision,maps:get(Peer,maps:get(links,S),#{}),0).

%% A fresh instance: peers see it as a new relationship and close the old one.
%% Packets from before this moment are not accepted from unknown instances, so
%% a restarted receiver cannot be fed recorded traffic.
reset(S,Now) ->
    S#{instance => fresh(16),seq => 0,started => wall(Now),links => #{},retired => #{},
       pending => #{},answering => #{}}.

%% Introduces this Device to a peer that has not heard from it; the peer answers
%% ready, after which both sides hold the relationship. Requests need no hello.
connect(Peer, Now, S) ->
    attempt(fun() ->
        sendable(Peer,Now,S),
        {Packet,Next} = outgoing(Peer,<<"hello">>,fresh(16),#{},Now,S),
        {ok,Packet,Next}
    end,S).

lease_ms(S) -> maps:get(lease_ms,S,60000).

request_status(Peer, Now, S) ->
    request(Peer,status,<<"status.read">>,Now,S).
request_capabilities(Peer, Now, S) ->
    request(Peer,capabilities,<<"capabilities.read">>,Now,S).
request_capabilities(Peer,true,Now,S) -> request(Peer,capabilities,<<"capabilities.read">>,#{<<"metrics">> => true},Now,S);
request_capabilities(Peer,false,Now,S) -> request_capabilities(Peer,Now,S);
request_capabilities(Peer,Options,Now,S) when is_map(Options) ->
    ok=ba_audio_diagnostics:validate_options(Options),
    request(Peer,capabilities,<<"capabilities.read">>,#{<<"metrics">> => true,<<"diagnostics">> => Options},Now,S).
request_inspection(Peer,Payload,Now,S) ->
    ok=ba_inspection:validate_request(Payload),
    request(Peer,inspection,<<"inspect.read">>,Payload,Now,S).
request(Peer,Kind,Operation,Now,S) -> request(Peer,Kind,Operation,#{},Now,S).
request(Peer,Kind,Operation,Payload,Now,S) ->
    attempt(fun() ->
        sendable(Peer,Now,S),
        Pending = maps:get(pending,S),
        false = maps:is_key(Peer,Pending),
        Request = fresh(16),
        {Packet,Next} = outgoing(Peer,Operation,Request,Payload,Now,S),
        {ok,Packet,Next#{pending := Pending#{Peer => #{request => Request,kind => Kind,deadline => Now+5000}}}}
    end,S).

%% Only the local adapter supplies capability data, after verified dispatch.
reply_capabilities(Peer,Request,Value,Now,S) ->
    attempt(fun() ->
        #{Peer := Request} = Answering = maps:get(answering,S),
        {Op,Payload} = case Value of
            unavailable -> {<<"capabilities.error">>,#{<<"reason">> => <<"unavailable">>}};
            {error,R} -> {<<"capabilities.error">>,#{<<"reason">> => atom_to_binary(R)}};
            _ -> capability_payload(Value), {<<"capabilities.reply">>,Value}
        end,
        {Packet,Next} = outgoing(Peer,Op,Request,Payload,Now,S),
        {ok,Packet,Next#{answering := maps:remove(Peer,Answering)}}
    end,S).

reply_inspection(Peer,Request,Value,Now,S) ->
    attempt(fun() ->
        #{Peer := Request}=Answering=maps:get(answering,S),
        {Op,Payload}=case Value of
            {ok,P} -> {<<"inspect.reply">>,P};
            {error,R} -> {<<"inspect.error">>,#{<<"reason">> => atom_to_binary(R)}}
        end,
        payload(Op,Payload),
        {Packet,Next}=outgoing(Peer,Op,Request,Payload,Now,S),
        {ok,Packet,Next#{answering := maps:remove(Peer,Answering)}}
    end,S).

%% Authentication stage of ba_device_request: every packet is verified against
%% its sender's key, the current installed policy, freshness and replay state
%% before anything else. A failure leaves the state unchanged.
receive_packet(From, Packet, Now, S) ->
    attempt(fun() ->
        true = Now < maps:get(membership_deadline,S,infinity),
        #{session := Session,invitation := Invitation,removed := Removed} = maps:get(policy,S),
        false = lists:member(From,Removed),
        Body = verify(Packet,From),
        #{<<"v">> := ?VERSION, <<"from">> := From, <<"to">> := To, <<"session">> := Session,
          <<"join">> := Join,<<"revision">> := Revision,
          <<"link">> := Instance,<<"seq">> := Sequence,<<"sent">> := Sent} = Body,
        To = maps:get(id,S),
        true = abs(wall(Now)-Sent) =< ?SKEW,
        true = ba_session_passport:joined(Session,From,Join,Invitation),
        {Admitted,Next} = admit(From,Instance,Sequence,Sent,Now,S),
        Known = maps:get(links,Next),
        Noted = Next#{links := Known#{From := (maps:get(From,Known))#{revision => Revision}}},
        {ok,Packets,Events,Final} = dispatch(From,Body,Now,Noted),
        {ok,Packets,Admitted++Events,Final}
    end,S).

%% Replay protection without a handshake: within one sender instance the
%% sequence only rises; a retired instance never returns; an unknown instance
%% must have been sent after this state started. Events tell the owner when a
%% relationship starts, is replaced or should extend its dependent leases.
admit(Peer,Instance,Sequence,Sent,Now,S) ->
    Retired = [R || {_,Until}=R <- maps:get(Peer,maps:get(retired,S),[]),Until > Now],
    false = lists:keymember(Instance,1,Retired),
    Links = maps:get(links,S),
    case maps:find(Peer,Links) of
        {ok,#{id := Instance,received := Last}=R} ->
            true = Sequence > Last,
            Live = R#{received := Sequence},
            case {Now < maps:get(deadline,R),maps:get(lapsed,R,false)} of
                {true,_} ->
                    Next = put(Peer,extend(Live,Now,S),S),
                    case Now >= maps:get(renew_after,R) of
                        false -> {[],Next};
                        true ->
                            Renewed = put(Peer,(extend(Live,Now,S))#{renew_after := Now+lease_ms(S) div 3,
                                renewals := maps:get(renewals,R)+1},S),
                            {[{link_renewed,context(Peer,Now,Renewed)}],Renewed}
                    end;
                %% Lapsed and already reported: the same instance resumes.
                {false,true} -> {[authorized],put(Peer,start(Live,Now,S),S)};
                %% Lapsed but not yet reported: close it like a replaced one.
                {false,false} -> {[{link_replaced,Instance},authorized],put(Peer,start(Live,Now,S),S)}
            end;
        Found ->
            true = Sent >= maps:get(started,S)-?START_SLACK,
            {Replaced,NowRetired} = case Found of
                {ok,#{id := Old}} -> {[{link_replaced,Old}],lists:sublist([{Old,Now+2*?SKEW}|Retired],?RETIRED)};
                error -> {[],Retired}
            end,
            New = start(#{id => Instance,received => Sequence},Now,S),
            Next = put(Peer,New,S#{retired := (maps:get(retired,S))#{Peer => NowRetired}}),
            {Replaced++[authorized],Next}
    end.
start(R,Now,S) -> (extend(maps:remove(lapsed,R),Now,S))#{renew_after => Now+lease_ms(S) div 3,renewals => 0}.
extend(R,Now,S) -> R#{deadline => min(Now+lease_ms(S),maps:get(membership_deadline,S,infinity))}.

context(Peer,Now,S) ->
    Link = active(Peer,Now,S),
    #{session := Session,manager := Manager} = maps:get(policy,S),
    #{peer => Peer,link => maps:get(id,Link),deadline => maps:get(deadline,Link),
      session => Session,manager => Manager}.
chat_message(Peer,Id,Text,Now,S) ->
    attempt(fun() ->
        true=ba_hex:valid(Id,32),Payload=#{<<"text">> => Text},payload(<<"chat.message">>,Payload),
        sendable(Peer,Now,S),
        {Packet,Next}=outgoing(Peer,<<"chat.message">>,Id,Payload,Now,S),{ok,Packet,Next}
    end,S).

audio_message(Peer,Id,Payload,Now,S) ->
    attempt(fun() ->
        true = ba_hex:valid(Id,32),ok = ba_audio_stream_protocol:validate(Payload),
        sendable(Peer,Now,S),
        {Packet,Next} = outgoing(Peer,<<"stream.message">>,Id,Payload,Now,S),
        {ok,Packet,Next}
    end,S).

%% Requests about the Link itself (rights, name, removal, End).
session_message(Peer,Id,Payload,Now,S) ->
    attempt(fun() ->
        true = ba_hex:valid(Id,32),payload(<<"session.request">>,Payload),
        sendable(Peer,Now,S),
        {Packet,Next} = outgoing(Peer,<<"session.request">>,Id,Payload,Now,S),
        {ok,Packet,Next}
    end,S).

dispatch(Peer,#{<<"op">> := <<"hello">>,<<"request">> := Request},Now,S) ->
    {Packet,Next} = outgoing(Peer,<<"ready">>,Request,#{},Now,S),
    {ok,[Packet],[],Next};
dispatch(_,#{<<"op">> := <<"ready">>},_,S) -> {ok,[],[],S};
dispatch(Peer, #{<<"op">> := Op,<<"request">> := Request,<<"payload">> := Payload,<<"sent">> := Sent}, Now, S) ->
    case {Op,Payload} of
        {<<"session.request">>,#{<<"kind">> := <<"playback_step">>}} ->
            true=abs(wall(Now)-Sent)=<30000;
        _ -> ok
    end,
    case ba_device_request:authorize(Op,Payload,held(Peer,S)) of
        ok -> authorized(Peer,Op,Request,Payload,Now,S);
        {error,forbidden} -> forbidden(Peer,Op,Request,Payload,Now,S)
    end.

%% A refusal keeps each operation's established error reply; operations
%% without one are dropped without changing replay state.
forbidden(Peer,Op,Request,_Payload,Now,S) ->
    {Reply,Value} = case Op of
        <<"status.read">> -> {<<"status.error">>,#{<<"reason">> => <<"forbidden">>}};
        <<"capabilities.read">> -> {<<"capabilities.error">>,#{<<"reason">> => <<"forbidden">>}};
        <<"inspect.read">> -> {<<"inspect.error">>,#{<<"reason">> => <<"forbidden">>}};
        _ -> error(forbidden)
    end,
    {Packet,Next} = outgoing(Peer,Reply,Request,Value,Now,S),
    {ok,[Packet],[],Next}.

authorized(Peer,Op,Request,Payload,Now,S) ->
    case Op of
        <<"chat.message">> ->
            {ok,[],[{chat,Request,maps:get(<<"text">>,Payload),context(Peer,Now,S)}],S};
        <<"session.request">> ->
            {ok,[],[{session,Request,Payload,context(Peer,Now,S)}],S};
        <<"stream.message">> ->
            {ok,[],[{audio,Request,Payload,context(Peer,Now,S)}],S};
        <<"status.read">> ->
            Value = #{<<"protocol">> => 1,<<"link">> => <<"authorized">>},
            {Packet,Next} = outgoing(Peer,<<"status.reply">>,Request,Value,Now,S),
            {ok,[Packet],[],Next};
        <<"capabilities.read">> ->
            Answering = maps:get(answering,S),
            false = maps:is_key(Peer,Answering),
            Event=case maps:find(<<"diagnostics">>,Payload) of
                {ok,Options} -> {capabilities_read,Request,true,Options};
                error -> case maps:get(<<"metrics">>,Payload,false) of true -> {capabilities_read,Request,true};false -> {capabilities_read,Request} end
            end,
            {ok,[],[Event],S#{answering := Answering#{Peer => Request}}};
        <<"inspect.read">> ->
            Answering=maps:get(answering,S),false=maps:is_key(Peer,Answering),
            {ok,[],[{inspect_read,Request,Payload}],S#{answering := Answering#{Peer => Request}}};
        _ when Op =:= <<"status.reply">>; Op =:= <<"status.error">>;
               Op =:= <<"capabilities.reply">>; Op =:= <<"capabilities.error">>;
               Op =:= <<"inspect.reply">>; Op =:= <<"inspect.error">> ->
            Pending = maps:get(pending,S),
            #{request := Request,kind := Kind,deadline := Deadline} = maps:get(Peer,Pending),
            Kind = case Op of
                <<"status.",_/binary>> -> status;
                <<"inspect.",_/binary>> -> inspection;
                _ -> capabilities
            end,
            true = Now < Deadline,
            {ok,[],[{reply,Op,Payload}],S#{pending := maps:remove(Peer,Pending)}}
    end.

active(Peer, Now, S) ->
    #{deadline := Deadline} = Link = maps:get(Peer,maps:get(links,S)),
    true = Now < Deadline,true = Now < maps:get(membership_deadline,S,infinity), Link.
sendable(Peer,Now,S) ->
    true = Now < maps:get(membership_deadline,S,infinity),
    true = ba_hex:valid(Peer,64) andalso Peer =/= maps:get(id,S),
    false = lists:member(Peer,maps:get(removed,maps:get(policy,S))).

%% Expiry is also checked synchronously on every receive/request, never just by a timer.
%% A lapsed relationship keeps its replay state until its packets are too old.
expire(Now, #{links := Links,pending := Pending} = S) ->
    {Kept,Events} = maps:fold(fun(Peer,R,{Acc,Es}) ->
        case {Now >= maps:get(deadline,R),maps:get(lapsed,R,false)} of
            {false,_} -> {Acc#{Peer => R},Es};
            {true,false} -> {Acc#{Peer => R#{lapsed => true}},[{Peer,link_expired}|Es]};
            {true,true} ->
                case Now >= maps:get(deadline,R)+2*?SKEW of
                    true -> {Acc,Es};
                    false -> {Acc#{Peer => R},Es}
                end
        end
    end,{#{},[]},Links),
    {Waiting,Timeouts} = maps:fold(fun(Peer,#{deadline := Due}=P,{Acc,Es}) ->
        case Due =< Now of
            true -> {Acc,[{Peer,request_timeout}|Es]};
            false -> {Acc#{Peer => P},Es}
        end
    end,{#{},[]},Pending),
    Retired = maps:filter(fun(_,L) -> L=/=[] end,
        maps:map(fun(_,L) -> [R || {_,Until}=R <- L,Until > Now] end,maps:get(retired,S))),
    {Events++Timeouts,S#{links := Kept,pending := Waiting,retired := Retired}}.
%% The owner closed a relationship (peer offline, excluded). Replay state stays
%% until expiry forgets it, so recorded packets cannot reopen it.
close(Peer,Now,#{links := Links}=S) ->
    case maps:find(Peer,Links) of
        {ok,R} -> S#{links := Links#{Peer := R#{lapsed => true,deadline := min(Now,maps:get(deadline,R))}},
                     pending := maps:remove(Peer,maps:get(pending,S)),answering := maps:remove(Peer,maps:get(answering,S))};
        error -> S
    end.
snapshot(S) ->
    #{id => maps:get(id,S),links => maps:map(fun(_,V) ->
        (maps:with([deadline,renewals],V))#{stage => case maps:get(lapsed,V,false) of true -> lapsed;false -> authorized end}
    end,maps:get(links,S))}.

outgoing(Peer, Op, Request, Payload, Now, S) ->
    #{session := Session,join := Join,revision := Revision} = maps:get(policy,S),
    Sequence = maps:get(seq,S)+1,
    true = uint(Sequence),
    Body = #{<<"v">> => ?VERSION,<<"from">> => maps:get(id,S),<<"to">> => Peer,
        <<"session">> => Session,<<"join">> => Join,<<"revision">> => Revision,
        <<"link">> => maps:get(instance,S),<<"seq">> => Sequence,<<"sent">> => wall(Now),
        <<"op">> => Op,<<"request">> => Request,<<"payload">> => Payload},
    {seal(Body,maps:get(private,S)),S#{seq := Sequence}}.
%% Callers pass monotonic milliseconds; the wire carries wall-clock time.
wall(Now) -> Now+erlang:time_offset(millisecond).

%% Exact body bytes are signed, with no term decoding, canonicalization or atom creation.
seal(Body, Private) ->
    Data = iolist_to_binary(json:encode(Body)),
    Signature = crypto:sign(eddsa,none,[?DOMAIN,Data],[Private,ed25519]),
    Packet = iolist_to_binary(json:encode(#{<<"body">> => base64:encode(Data),
                                          <<"signature">> => binary:encode_hex(Signature)})),
    true = byte_size(Packet) =< ?MAX, Packet.
verify(Packet, From) when is_binary(Packet), byte_size(Packet) =< ?MAX ->
    Envelope = decode(Packet), ba_session_passport:exact(Envelope,[<<"body">>,<<"signature">>]),
    Encoded = maps:get(<<"body">>,Envelope), true = is_binary(Encoded),
    Sig = maps:get(<<"signature">>,Envelope), true = ba_hex:valid(Sig,128),
    Data = base64:decode(Encoded),
    true = crypto:verify(eddsa,none,[?DOMAIN,Data],binary:decode_hex(Sig),
                         [binary:decode_hex(From),ed25519]),
    Body = decode(Data),
    ba_session_passport:exact(Body,[<<"v">>,<<"from">>,<<"to">>,<<"session">>,<<"join">>,<<"revision">>,
                <<"link">>,<<"seq">>,<<"sent">>,<<"op">>,<<"request">>,<<"payload">>]),
    [true = ba_hex:valid(maps:get(K,Body),N) || {K,N} <-
        [{<<"from">>,64},{<<"to">>,64},{<<"session">>,32},{<<"join">>,128},
         {<<"link">>,32},{<<"request">>,32}]],
    [true = uint(maps:get(K,Body)) || K <- [<<"seq">>,<<"revision">>,<<"sent">>]],
    payload(maps:get(<<"op">>,Body),maps:get(<<"payload">>,Body)), Body.

payload(Op,P) when Op =:= <<"hello">>; Op =:= <<"ready">> -> ba_session_passport:exact(P,[]);
payload(<<"chat.message">>,P) ->
    ba_session_passport:exact(P,[<<"text">>]),Text=maps:get(<<"text">>,P),
    true=is_binary(Text) andalso byte_size(Text)>0 andalso byte_size(Text)=<4096,
    true=is_list(unicode:characters_to_list(Text));
payload(<<"session.request">>,#{<<"kind">> := Kind}=P) ->
    case Kind of
        <<"playback_step">> -> ba_playback_control:validate(P);
        <<"playback_result">> -> ba_playback_control:validate(P);
        %% A gossiped note (ba_session_gossip checks its signature).
        <<"note">> ->
            ba_session_passport:exact(P,[<<"kind">>,<<"id">>,<<"packet">>]),true = ba_hex:valid(maps:get(<<"id">>,P),32),
            Note = maps:get(<<"packet">>,P),true = is_binary(Note) andalso byte_size(Note) =< 6144;
        %% Request board entries (ba_session_board checks each signature).
        <<"board">> ->
            ba_session_passport:exact(P,[<<"kind">>,<<"entries">>]),Entries = maps:get(<<"entries">>,P),
            true = is_map(Entries) andalso map_size(Entries) =< 6,
            maps:foreach(fun(Id,E) -> true = ba_hex:valid(Id,32) andalso is_binary(E) andalso byte_size(E) =< 2048 end,Entries);
        <<"privilege_release">> ->
            ba_session_passport:exact(P,[<<"kind">>,<<"privilege">>]),ok = ba_session_passport:permissions([maps:get(<<"privilege">>,P)]);
        <<"rename_request">> ->
            ba_session_passport:exact(P,[<<"kind">>,<<"name">>]),Name = maps:get(<<"name">>,P),
            true = is_binary(Name) andalso byte_size(Name)>0 andalso byte_size(Name)=<128,
            true = is_list(unicode:characters_to_list(Name));
        <<"response_request">> ->
            case P of
                #{<<"selection">> := Choice} ->
                    ba_session_passport:exact(P,[<<"kind">>,<<"selection">>]),
                    ok = ba_response_time:valid_selection(Choice);
                #{<<"response_ms">> := Ms} ->
                    ba_session_passport:exact(P,[<<"kind">>,<<"response_ms">>]),
                    ok = ba_response_time:valid(Ms)
            end;
        <<"remove_request">> -> ba_session_passport:exact(P,[<<"kind">>,<<"device">>]),true = ba_hex:valid(maps:get(<<"device">>,P),64);
        <<"ended">> -> ba_session_passport:exact(P,[<<"kind">>]);
        %% A signed rights statement; membership verifies its signer chain.
        <<"policy">> ->
            ba_session_passport:exact(P,[<<"kind">>,<<"signer">>,<<"state">>]),true = ba_hex:valid(maps:get(<<"signer">>,P),64),
            State = maps:get(<<"state">>,P),true = is_binary(State) andalso byte_size(State) =< 16384
    end;
payload(<<"status.read">>,P) -> ba_session_passport:exact(P,[]);
payload(<<"status.reply">>,P) ->
    ba_session_passport:exact(P,[<<"protocol">>,<<"link">>]),
    #{<<"protocol">> := 1,<<"link">> := <<"authorized">>} = P;
payload(<<"status.error">>,P) ->
    ba_session_passport:exact(P,[<<"reason">>]), #{<<"reason">> := <<"forbidden">>} = P;
payload(<<"capabilities.read">>,#{<<"metrics">> := true,<<"diagnostics">> := Options}=P) ->
    ba_session_passport:exact(P,[<<"metrics">>,<<"diagnostics">>]),ba_audio_diagnostics:validate_options(Options);
payload(<<"capabilities.read">>,#{<<"metrics">> := true}=P) -> ba_session_passport:exact(P,[<<"metrics">>]);
payload(<<"capabilities.read">>,P) -> ba_session_passport:exact(P,[]);
payload(<<"capabilities.reply">>,P) -> capability_payload(P);
payload(<<"capabilities.error">>,P) ->
    ba_session_passport:exact(P,[<<"reason">>]),
    Reason = maps:get(<<"reason">>,P),
    true = ba_inspection:error(Reason);
payload(<<"inspect.read">>,P) -> ba_inspection:validate_request(P);
payload(<<"inspect.reply">>,P) -> ba_inspection:validate_reply(P);
payload(<<"inspect.error">>,P) ->
    ba_session_passport:exact(P,[<<"reason">>]),true=ba_inspection:error(maps:get(<<"reason">>,P));
payload(<<"stream.message">>,P) -> ba_audio_stream_protocol:validate(P);
payload(_,_) -> throw(forbidden_operation).

capability_payload(P) ->
    ba_session_passport:exact(P,[<<"instance">>,<<"revision">>]++[K || K <- [<<"audio">>,<<"device_name">>,<<"audio_diagnostics">>,<<"audio_trace">>,<<"audio_meters">>,<<"playback_control">>],maps:is_key(K,P)]),
    case maps:find(<<"playback_control">>,P) of error -> ok;{ok,Offer} -> true=lists:member(Offer,[<<"always">>,<<"ask">>]) end,
    case maps:find(<<"audio_meters">>,P) of error -> ok;{ok,Meters} -> ba_audio_diagnostics:validate_meters(Meters) end,
    case maps:find(<<"audio_trace">>,P) of error -> ok;{ok,Trace} -> ba_audio_diagnostics:validate_trace(Trace) end,
    case maps:find(<<"audio_diagnostics">>,P) of error -> ok;{ok,D} -> ba_audio_diagnostics:validate(D) end,
    case maps:find(<<"device_name">>,P) of
        error -> ok;
        {ok,Name} -> true=is_binary(Name) andalso byte_size(Name)>0 andalso byte_size(Name)=<256,
            true=is_list(unicode:characters_to_list(Name))
    end,
    case maps:find(<<"audio">>,P) of
        {ok,Audio} ->
            ba_session_passport:exact(Audio,[<<"speaker">>,<<"microphone">>,<<"broadcast">>]),
            maps:foreach(fun(_,Entry) ->
                Extra=[<<"error">>,<<"peak_db">>,<<"rms_db">>,<<"meter_age_ms">>,<<"meter_stage">>,<<"blocks">>,<<"frames">>,<<"dropped">>],
                ba_session_passport:exact(Entry,[<<"consent">>,<<"state">>,<<"available">>]++[K || K <- Extra,maps:is_key(K,Entry)]),
                [begin V=maps:get(K,Entry),true=is_number(V) andalso V>= -96 andalso V=<48 end || K <- [<<"peak_db">>,<<"rms_db">>],maps:is_key(K,Entry)],
                [true=uint(maps:get(K,Entry)) || K <- [<<"meter_age_ms">>,<<"blocks">>,<<"frames">>,<<"dropped">>],maps:is_key(K,Entry)],
                case maps:find(<<"meter_stage">>,Entry) of error -> ok;{ok,Stage} -> true=lists:member(Stage,[<<"capture">>,<<"receive_max">>,<<"output_submitted">>]) end,
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
    true = ba_hex:valid(maps:get(<<"instance">>,P),32),true = uint(maps:get(<<"revision">>,P)).

%% Reject duplicate keys, arrays, excess nesting and oversized number strings.
decode(Data) ->
    {Value,_,<<>>} = json:decode(Data,{0,#{}},#{
        object_start => fun({Depth,_}) -> true = Depth < 5, {Depth+1,#{}} end,
        object_push => fun(K,V,{D,M}) -> false = maps:is_key(K,M), {D,M#{K => V}} end,
        object_finish => fun({_,M},Old) -> {M,Old} end,
        array_start => fun(_) -> error(arrays_not_allowed) end,
        integer => fun(B) -> true = byte_size(B) =< 16, binary_to_integer(B) end}), Value.
uint(N) -> is_integer(N) andalso N >= 0 andalso N =< ?INT.
fresh(N) -> binary:encode_hex(crypto:strong_rand_bytes(N)).
put(Peer,Link,#{links := Links} = S) -> S#{links := Links#{Peer => Link}}.
attempt(Fun,S) ->
    try Fun() catch
        throw:forbidden_operation -> {error,forbidden_operation,S};
        _:_ -> {error,invalid_or_unauthorized,S}
    end.
