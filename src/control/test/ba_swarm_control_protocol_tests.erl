-module(ba_swarm_control_protocol_tests).
-include_lib("eunit/include/eunit.hrl").

fixture() ->
    KA = {PA,_} = crypto:generate_key(eddsa,ed25519),
    KB = {PB,_} = crypto:generate_key(eddsa,ed25519),
    A = binary:encode_hex(PA), B = binary:encode_hex(PB),
    Common = #{swarm => binary:copy(<<"A">>,32),authority => A,director => A,epoch => 1,revision => 1},
    {A,B,KA,KB,
     ba_swarm_control_protocol:new(KA,Common#{peers => #{B => [status_read]}}),
     ba_swarm_control_protocol:new(KB,Common#{peers => #{A => [status_read]}})}.

otp_diagnostics_redact_keys_test() ->
    {_,_,_,_,P,_} = fixture(),
    Secret = <<"test-only-private-key-must-not-appear">>,
    Status = #{state => #{protocol => P#{private := Secret},private => Secret},
               message => Secret,reason => Secret,log => [Secret]},
    [?assertEqual(nomatch,binary:match(term_to_binary(Formatted),Secret)) || Formatted <-
        [ba_swarm_control:format_status(Status),ba_relay:format_status(Status)]].

handshake() ->
    {A,B,KA,KB,SA,SB} = fixture(),
    {ok,Hello,A1} = p(connect,[B,0,SA]),
    {ok,[Challenge],[],B1} = p(receive_packet,[A,Hello,1,SB]),
    {ok,[Proof],[],A2} = p(receive_packet,[B,Challenge,2,A1]),
    {ok,[Ready],[],B2} = p(receive_packet,[A,Proof,3,B1]),
    {ok,[],[authorized],A3} = p(receive_packet,[B,Ready,4,A2]),
    {A,B,KA,KB,A3,B2,Hello,Challenge,Proof,Ready}.

status_roundtrip_and_replay_test() ->
    {A,B,_,_,SA,SB,_,_,_,_} = handshake(),
    {ok,Request,A1} = p(request_status,[B,5,SA]),
    {ok,[Response],[],B1} = p(receive_packet,[A,Request,6,SB]),
    {ok,[],[{reply,<<"status.reply">>,#{<<"protocol">> := 1}}],A2} =
        p(receive_packet,[B,Response,7,A1]),
    ?assertMatch({error,_,B1},p(receive_packet,[A,Request,8,B1])),
    ?assertMatch({error,_,A2},p(receive_packet,[B,Response,8,A2])).

capability_permissions_and_reply_test() ->
    {A,B,_,KB,SA,SB,_,_,_,_} = handshake(),
    {ok,Denied,A0} = p(request_capabilities,[B,5,SA]),
    {ok,[Error],[],_} = p(receive_packet,[A,Denied,6,SB]),
    ?assertMatch({ok,[],[{reply,<<"capabilities.error">>,#{<<"reason">> := <<"forbidden">>}}],_},
        p(receive_packet,[B,Error,7,A0])),
    Policy = maps:get(policy,SB),
    Granted = SB#{policy := Policy#{peers := #{A => [capabilities_read,status_read]}}},
    {ok,Query,A1} = p(request_capabilities,[B,5,SA]),
    {ok,[],[{capabilities_read,Request}],B1} = p(receive_packet,[A,Query,6,Granted]),
    Caps = #{<<"instance">> => binary:copy(<<"A">>,32),<<"revision">> => 0,<<"test">> => #{
        <<"supported">> => true,<<"available">> => false,<<"requires_consent">> => true,
        <<"consent">> => false,<<"capacity">> => 2,<<"active">> => 0,<<"max_duration_ms">> => 10000}},
    {ok,Reply,B2} = p(reply_capabilities,[A,Request,Caps,7,B1]),
    WrongKind = resign(Reply,KB,fun(M) -> M#{<<"op">> := <<"status.reply">>,
        <<"payload">> := #{<<"protocol">> => 1,<<"session">> => <<"authorized">>}} end),
    ?assertMatch({error,_,A1},p(receive_packet,[B,WrongKind,8,A1])),
    BadCaps = resign(Reply,KB,fun(M) -> M#{<<"payload">> := Caps#{<<"module">> => <<"os">>}} end),
    ?assertMatch({error,_,A1},p(receive_packet,[B,BadCaps,8,A1])),
    {ok,[],[{reply,<<"capabilities.reply">>,Caps}],A2} = p(receive_packet,[B,Reply,8,A1]),
    ?assertMatch({error,_,A2},p(receive_packet,[B,Reply,9,A2])),
    ?assertMatch({error,_,B2},p(reply_capabilities,[A,Request,Caps,9,B2])),
    {ok,Unavailable,_} = p(reply_capabilities,[A,Request,unavailable,7,B1]),
    ?assertMatch({ok,[],[{reply,<<"capabilities.error">>,#{<<"reason">> := <<"unavailable">>}}],_},
        p(receive_packet,[B,Unavailable,8,A1])).

director_and_job_grant_test() ->
    {A,B,KA,KB,SA,SB,_,_,_,_} = handshake(),
    Id = binary:copy(<<"C">>,32), Offer = job_offer(),
    {ok,Packet,_} = p(job_message,[B,<<"job.offer">>,Id,Offer,5,SA]),
    ?assertMatch({error,_,SB},p(receive_packet,[A,Packet,6,SB])),
    PolicyB = maps:get(policy,SB),
    GrantedB = SB#{policy := PolicyB#{peers := #{A => [job_offer,status_read]}}},
    ?assertMatch({ok,[],[{job,<<"job.offer">>,Id,Offer,#{peer := A,director := A}}],_},
        p(receive_packet,[A,Packet,6,GrantedB])),
    ?assertMatch({error,_,SB},p(job_message,[A,<<"job.offer">>,Id,Offer,5,SB])),
    PolicyA = maps:get(policy,SA),
    GrantedA = SA#{policy := PolicyA#{peers := #{B => [job_offer,status_read]}}},
    Impostor = resign(Packet,KB,fun(M) -> M#{<<"from">> := B,<<"to">> := A} end),
    ?assertMatch({error,_,GrantedA},p(receive_packet,[B,Impostor,6,GrantedA])),
    BadDirector = resign(Packet,KA,fun(M) -> M#{<<"director">> := B} end),
    ?assertMatch({error,_,GrantedB},p(receive_packet,[A,BadDirector,6,GrantedB])).

job_schema_and_expiry_test() ->
    {A,B,KA,_,SA,SB,_,_,_,_} = handshake(),
    Id = binary:copy(<<"C">>,32), Offer = job_offer(),
    Policy = maps:get(policy,SB), Granted = SB#{policy := Policy#{peers := #{A => [job_offer]}}},
    {ok,Packet,_} = p(job_message,[B,<<"job.offer">>,Id,Offer,5,SA]),
    [?assertMatch({error,_,Granted},p(receive_packet,[A,
        resign(Packet,KA,fun(M) -> M#{<<"payload">> := Bad} end),6,Granted])) || Bad <-
        [Offer#{<<"module">> => <<"os">>},Offer#{<<"capability">> := <<"microphone">>},
         Offer#{<<"lease_ms">> := 0},Offer#{<<"lease_ms">> := 10001},
         Offer#{<<"contract_revision">> := 0},Offer#{<<"duration_ms">> := 20.5}]],
    ?assertMatch({error,_,SA},p(job_message,[B,<<"job.offer">>,Id,Offer,60004,SA])),
    ?assertException(error,_,ba_swarm_job:validate_report(
        #{<<"state">> => <<"accepted">>,<<"attempt">> => null,<<"reason">> => <<"none">>})).

job_offer() -> #{<<"contract">> => binary:copy(<<"D">>,32),<<"contract_revision">> => 1,
    <<"capability">> => <<"test">>,<<"duration_ms">> => 1000,<<"lease_ms">> => 5000}.

preauth_and_nonce_replay_test() ->
    {A,B,KA,_,SA,SB,Hello,Challenge,Proof,Ready} = handshake(),
    {_,_,_,_,_,FreshB} = fixture(),
    %% A fully valid signed application packet still needs an authorized session.
    {ok,Request,_} = p(request_status,[B,5,SA]),
    ?assertMatch({error,_,_},p(receive_packet,[A,Request,5,p(reset,[SB])])),
    ?assertMatch({error,_,SA},p(receive_packet,[B,Challenge,5,SA])),
    ?assertMatch({error,_,SB},p(receive_packet,[A,Proof,5,SB])),
    ?assertMatch({error,_,SA},p(receive_packet,[B,Ready,5,SA])),
    %% Replayed hello obtains a fresh responder nonce; the captured proof fails.
    {ok,[_],[],NewB} = p(receive_packet,[A,Hello,10,p(reset,[SB])]),
    ?assertMatch({error,_,NewB},p(receive_packet,[A,Proof,11,NewB])),
    ?assertMatch({error,_,FreshB},p(receive_packet,[A,Hello,10,FreshB])),
    BadHello = resign(Hello,KA,fun(M) -> M#{<<"payload">> := #{<<"a">> => binary:copy(<<"0">>,64),<<"b">> => 12}} end),
    ?assertMatch({error,_,_},p(receive_packet,[A,BadHello,10,p(reset,[SB])])).

forgery_recipient_scope_and_policy_test() ->
    {A,B,KA,KB,SA,SB,_,_,_,_} = handshake(),
    {ok,Request,_} = p(request_status,[B,5,SA]),
    BadSigner = resign(Request,KB,fun(M) -> M end),
    ?assertMatch({error,_,SB},p(receive_packet,[A,BadSigner,6,SB])),
    ?assertMatch({error,_,SB},p(receive_packet,[B,Request,6,SB])),
    [?assertMatch({error,_,SB},p(receive_packet,[A,resign(Request,KA,F),6,SB])) || F <-
        [fun(M) -> M#{<<"to">> := A} end,
         fun(M) -> M#{<<"swarm">> := binary:copy(<<"B">>,32)} end,
         fun(M) -> M#{<<"authority">> := B} end,
         fun(M) -> M#{<<"epoch">> := 2} end,
         fun(M) -> M#{<<"revision">> := 0} end,
         fun(M) -> M#{<<"v">> := 999} end,
         fun(M) -> M#{<<"extra">> => true} end,
         fun(M) -> M#{<<"payload">> := #{<<"module">> => <<"os">>}} end]],
    %% A forged high sequence cannot advance replay state.
    ForgedHigh = resign(Request,KB,fun(M) -> M#{<<"seq">> := 500} end),
    ?assertMatch({error,_,SB},p(receive_packet,[A,ForgedHigh,6,SB])),
    ?assertMatch({ok,[_],[],_},p(receive_packet,[A,Request,7,SB])).

forbidden_operation_test() ->
    {A,B,KA,_,SA,SB,_,_,_,_} = handshake(),
    {ok,Request,_} = p(request_status,[B,5,SA]),
    [?assertEqual({error,forbidden_operation,SB},p(receive_packet,
        [A,resign(Request,KA,fun(M) -> M#{<<"op">> := Op} end),6,SB])) ||
        Op <- [<<"worker.start">>,<<"rpc">>,<<"os.cmd">>,<<"broadcast_start">>]].

permission_and_correlation_test() ->
    {A,B,_,KB,SA,SB,_,_,_,_} = handshake(),
    {ok,Request,A1} = p(request_status,[B,5,SA]),
    Policy = maps:get(policy,SB),
    Denied = SB#{policy := Policy#{peers := #{A => []}}},
    {ok,[Error],[],_} = p(receive_packet,[A,Request,6,Denied]),
    ?assertMatch({ok,[],[{reply,<<"status.error">>,_}],_},p(receive_packet,[B,Error,7,A1])),
    {ok,[Response],[],_} = p(receive_packet,[A,Request,6,SB]),
    ?assertMatch({error,_,SA},p(receive_packet,[B,Response,7,SA])),
    WrongId = resign(Response,KB,fun(M) -> M#{<<"request">> := binary:copy(<<"0">>,32)} end),
    ?assertMatch({error,_,A1},p(receive_packet,[B,WrongId,7,A1])),
    ?assertMatch({error,_,A1},p(request_status,[B,8,A1])),
    ?assertMatch({error,_,A1},p(receive_packet,[B,Response,5005,A1])).

expiry_timeout_and_reset_test() ->
    {A,B,_,_,SA,SB,_,_,_,_} = handshake(),
    {ok,Request,A1} = p(request_status,[B,5,SA]),
    ?assertMatch({[{B,request_timeout}],_},p(expire,[5005,A1])),
    ?assertMatch({error,_,SB},p(receive_packet,[A,Request,60003,SB])),
    ?assertMatch({[{B,session_expired}],_},p(expire,[60004,A1])),
    ?assertEqual(#{},maps:get(sessions,p(snapshot,[p(reset,[SA])]))),
    ?assertMatch({error,_,_},p(request_status,[B,60004,SA])).

handshake_timeout_test() ->
    {A,B,_,_,SA,SB} = fixture(),
    {ok,Hello,A1} = p(connect,[B,0,SA]),
    {ok,[Challenge],[],_} = p(receive_packet,[A,Hello,1,SB]),
    ?assertMatch({error,_,A1},p(receive_packet,[B,Challenge,10000,A1])),
    ?assertMatch({[{B,session_expired}],_},p(expire,[10000,A1])).

malformed_and_size_test() ->
    {A,B,KA,_,SA,SB,_,_,_,_} = handshake(),
    {ok,Request,_} = p(request_status,[B,5,SA]),
    [?assertMatch({error,_,SB},p(receive_packet,[A,Wire,6,SB])) ||
        Wire <- [binary:copy(<<"x">>,32769),<<"garbage">>,<<"[]">>,<<"{}">>,<<255>>,42,
                 <<"{\"body\":\"a\",\"body\":\"b\",\"signature\":\"c\"}">>]],
    Body = body(Request),
    Data = iolist_to_binary(json:encode(Body)),
    <<"{",Rest/binary>> = Data,
    Duplicate = <<"{\"v\":1,",Rest/binary>>,
    ?assertMatch({error,_,SB},p(receive_packet,[A,raw_seal(Duplicate,element(2,KA)),6,SB])),
    BadArray = resign(Request,KA,fun(M) -> M#{<<"payload">> := []} end),
    ?assertMatch({error,_,SB},p(receive_packet,[A,BadArray,6,SB])),
    ?assertMatch({error,_,SB},p(receive_packet,[A,<<Request/binary,"x">>,6,SB])).

membership_and_limits_test() ->
    {A,B,KA,_,SA,SB,Hello,_,_,_} = handshake(),
    Policy = maps:get(policy,SB),
    Removed = SB#{policy := Policy#{authority := B,peers := #{}}},
    ?assertMatch({error,_,Removed},p(receive_packet,[A,Hello,6,Removed])),
    ?assertException(error,_,p(new,[KA,(maps:get(policy,SA))#{extra => true}])),
    ?assertMatch({error,_,SA},p(connect,[binary:copy(<<"0">>,64),6,SA])),
    ?assertMatch({error,_,SA},p(connect,[B,6,SA])),
    TooMany = maps:from_list([{binary:encode_hex(crypto:strong_rand_bytes(32)),[]} || _ <- lists:seq(1,33)]),
    ?assertException(error,_,p(new,[KA,(maps:get(policy,SA))#{peers := TooMany}])).

p(F,Args) -> apply(ba_swarm_control_protocol,F,Args).
body(Wire) -> json:decode(base64:decode(maps:get(<<"body">>,json:decode(Wire)))).
resign(Packet,{_,Private},Fun) -> p(seal,[Fun(body(Packet)),Private]).
raw_seal(Data,Private) ->
    Sig = crypto:sign(eddsa,none,[<<"parvi-swarm-control/v1:">>,Data],[Private,ed25519]),
    iolist_to_binary(json:encode(#{<<"body">> => base64:encode(Data),<<"signature">> => binary:encode_hex(Sig)})).

membership_deadline_is_synchronous_test() ->
    {A,B,_,_,SA,SB,_,_,_,_} = handshake(),
    Expired = SA#{membership_deadline => 5},
    ?assertMatch({error,_,_},p(request_status,[B,5,Expired])),
    {ok,Packet,_} = p(request_status,[A,5,SB]),
    ?assertMatch({error,_,_},p(receive_packet,[B,Packet,5,Expired])),
    {_,Peer,_,_,Fresh,_} = fixture(),
    ?assertMatch({error,_,_},p(connect,[Peer,5,Fresh#{membership_deadline => 5}])).

stream_control_requires_grants_and_exact_schema_test() ->
    {A,B,_,_,SA,SB,_,_,_,_} = handshake(),
    Id = binary:copy(<<"A">>,32),P = #{<<"kind">> => <<"catalog.read">>},
    {ok,Packet,_} = p(audio_message,[B,Id,P,5,SA]),
    ?assertMatch({error,_,SB},p(receive_packet,[A,Packet,6,SB])),
    Policy = maps:get(policy,SB),
    Granted = SB#{policy := Policy#{peers := #{A => [stream_read,stream_subscribe]}}},
    ?assertMatch({ok,[],[{audio,Id,P,#{peer := A}}],_},p(receive_packet,[A,Packet,6,Granted])),
    Base = #{<<"source">> => <<"music">>,<<"incarnation">> => Id,<<"attempt">> => Id},
    ?assertMatch({error,_,_},p(audio_message,[B,Id,Base#{<<"kind">> => <<"signal.offer">>,<<"sdp">> => <<"unsigned generic SDP">>},5,SA])),
    ?assertMatch({error,_,_},p(audio_message,[B,Id,P#{<<"pcm">> => <<"audio is not control">>},5,SA])).

fresh_reconnect_does_not_replace_active_session_until_proven_test() ->
    {A,B,_,_,SA,SB,_,_,_,_} = handshake(),
    Old = maps:get(id,maps:get(A,maps:get(sessions,SB))),
    {ok,Hello,A1} = p(connect,[B,10,p(reset,[SA])]),
    {ok,[Challenge],[],B1} = p(receive_packet,[A,Hello,11,SB]),
    ?assertEqual(maps:get(sessions,SB),maps:get(sessions,B1)),
    {ok,Proof,A2} = case p(receive_packet,[B,Challenge,12,A1]) of {ok,[P],[],N} -> {ok,P,N} end,
    {ok,[Ready],[{session_replaced,Old}],B2} = p(receive_packet,[A,Proof,13,B1]),
    {ok,[],[authorized],_} = p(receive_packet,[B,Ready,14,A2]),
    ?assertNotEqual(Old,maps:get(id,maps:get(A,maps:get(sessions,B2)))),
    ?assertMatch({error,_,B2},p(receive_packet,[A,Proof,15,B2])).

time_permission_is_not_implied_by_status_or_membership_test() ->
    {A,B,_,_,SA,SB,_,_,_,_} = handshake(),Id = binary:copy(<<"A">>,32),
    P = #{<<"kind">> => <<"offset.set">>,<<"revision">> => 1,<<"offset_ms">> => 250},
    {ok,Packet,_} = p(time_message,[B,Id,P,5,SA]),
    ?assertMatch({ok,[_],[],_},p(receive_packet,[A,Packet,6,SB])),
    Policy = maps:get(policy,SB),Granted = SB#{policy := Policy#{peers := #{A => [offset_write]}}},
    ?assertMatch({ok,[],[{time,Id,P,_}],_},p(receive_packet,[A,Packet,6,Granted])).

new_handshake_after_expiry_discards_an_older_candidate_test() ->
    {A,B,_,_,SA,SB,_,_,_,_} = handshake(),
    {ok,FirstHello,_} = p(connect,[B,59000,p(reset,[SA])]),
    {ok,[_],[],CandidateB} = p(receive_packet,[A,FirstHello,59001,SB]),
    {_,ExpiredB} = p(expire,[60004,CandidateB]),
    {ok,Hello,A1} = p(connect,[B,61000,p(reset,[SA])]),
    {ok,[Challenge],[],B1} = p(receive_packet,[A,Hello,61001,ExpiredB]),
    {ok,[Proof],[],A2} = p(receive_packet,[B,Challenge,61002,A1]),
    {ok,[Ready],[],_} = p(receive_packet,[A,Proof,61003,B1]),
    ?assertMatch({ok,[],[authorized],_},p(receive_packet,[B,Ready,61004,A2])).

renewal_requires_fresh_nonce_proof_and_preserves_session_test() ->
    {A,B,KA,_,SA,SB,_,_,_,_} = handshake(),
    OldA = p(context,[B,100,SA]),OldB = p(context,[A,100,SB]),
    {ok,Request,A1} = p(renew,[B,20000,SA]),
    {ok,[Challenge],[],B1} = p(receive_packet,[A,Request,20001,SB]),
    ?assertEqual(OldB,p(context,[A,20001,B1])),
    {ok,[Proof],[],A2} = p(receive_packet,[B,Challenge,20002,A1]),
    Bad = resign(Proof,KA,fun(M) -> M#{<<"payload">> := (maps:get(<<"payload">>,M))#{<<"b">> := binary:copy(<<"0">>,64)}} end),
    ?assertMatch({error,_,B1},p(receive_packet,[A,Bad,20003,B1])),
    {ok,[Ready],[{session_renewed,CB}],B2} = p(receive_packet,[A,Proof,20003,B1]),
    {ok,[],[{session_renewed,CA}],A3} = p(receive_packet,[B,Ready,20004,A2]),
    ?assertEqual(maps:get(session,OldA),maps:get(session,CA)),
    ?assertEqual(maps:get(session,OldB),maps:get(session,CB)),
    ?assert(maps:get(deadline,CA)>maps:get(deadline,OldA)),
    ?assertMatch({error,_,A3},p(receive_packet,[B,Ready,20005,A3])),
    ?assertMatch({error,_,B2},p(receive_packet,[A,Proof,20005,B2])),
    {ok,Query,A4} = p(request_status,[B,60005,A3]),
    ?assertMatch({ok,[_],[],_},p(receive_packet,[A,Query,60006,B2])),
    ?assertMatch({error,_,A4},p(renew,[B,90000,A4])).

withheld_renewal_does_not_extend_authorization_test() ->
    {A,B,_,_,SA,SB,_,_,_,_} = handshake(),
    {ok,Request,A1} = p(renew,[B,20000,SA]),
    {ok,[_],[],B1} = p(receive_packet,[A,Request,20001,SB]),
    {_,A2} = p(expire,[25001,A1]),{_,B2} = p(expire,[25002,B1]),
    ?assertEqual(p(context,[B,100,SA]),p(context,[B,30000,A2])),
    ?assertEqual(p(context,[A,100,SB]),p(context,[A,30000,B2])),
    ?assertMatch({error,_,_},p(request_status,[B,60005,A2])),
    ?assertEqual(1,length(p(renew_due,[30000,A2]))+length(p(renew_due,[30000,B2]))).

renewal_is_capped_by_fresh_membership_test() ->
    {A,B,_,_,SA,SB,_,_,_,_} = handshake(),
    {ok,Request,A1} = p(renew,[B,20000,SA#{membership_deadline => 65000}]),
    {ok,[Challenge],[],B1} = p(receive_packet,[A,Request,20001,SB#{membership_deadline => 66000}]),
    {ok,[Proof],[],A2} = p(receive_packet,[B,Challenge,20002,A1]),
    {ok,[Ready],_,_} = p(receive_packet,[A,Proof,20003,B1]),
    {ok,[],[{session_renewed,#{deadline := 65000}}],A3} = p(receive_packet,[B,Ready,20004,A2]),
    ?assertMatch({error,_,A3},p(request_status,[B,65000,A3])).

chat_is_authenticated_bounded_and_replay_protected_test() ->
    {A,B,_,_,SA,SB,_,_,_,_}=handshake(),Id=binary:copy(<<"D">>,32),
    {ok,Packet,A1}=p(chat_message,[B,Id,<<"hello">>,5,SA]),
    {ok,[],[{chat,Id,<<"hello">>,#{peer := A}}],B1}=p(receive_packet,[A,Packet,6,SB]),
    ?assertMatch({error,_,B1},p(receive_packet,[A,Packet,7,B1])),
    ?assertMatch({error,_,A1},p(chat_message,[B,Id,binary:copy(<<"x">>,4097),8,A1])),
    ?assertMatch({error,_,SB},p(chat_message,[A,Id,<<"later">>,100000,SB])).

audio_capability_shape_is_bounded_and_authenticated_test() ->
    {A,B,_,_,SA,SB,_,_,_,_}=handshake(),Policy=maps:get(policy,SB),
    Granted=SB#{policy := Policy#{peers := #{A => [capabilities_read,status_read]}}},
    {ok,Query,A1}=p(request_capabilities,[B,5,SA]),
    {ok,[],[{capabilities_read,Id}],B1}=p(receive_packet,[A,Query,6,Granted]),
    Entry=#{<<"consent">> => true,<<"available">> => false,<<"state">> => <<"waiting_for_clock">>},
    Caps=#{<<"instance">> => binary:copy(<<"A">>,32),<<"revision">> => 0,
        <<"audio">> => #{<<"speaker">> => Entry,<<"microphone">> => Entry,<<"broadcast">> => Entry},
        <<"test">> => #{<<"supported">> => true,<<"available">> => false,<<"requires_consent">> => true,
            <<"consent">> => false,<<"capacity">> => 2,<<"active">> => 0,<<"max_duration_ms">> => 10000}},
    {ok,Reply,_}=p(reply_capabilities,[A,Id,Caps,7,B1]),
    ?assertMatch({ok,[],[{reply,<<"capabilities.reply">>,Caps}],_},p(receive_packet,[B,Reply,8,A1])),
    Bad=Caps#{<<"audio">> := (maps:get(<<"audio">>,Caps))#{<<"execute">> => Entry}},
    ?assertMatch({error,_,B1},p(reply_capabilities,[A,Id,Bad,7,B1])).
