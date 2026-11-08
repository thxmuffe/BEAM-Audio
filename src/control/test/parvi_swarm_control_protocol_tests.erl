-module(parvi_swarm_control_protocol_tests).
-include_lib("eunit/include/eunit.hrl").

fixture() ->
    KA = {PA,_} = crypto:generate_key(eddsa,ed25519),
    KB = {PB,_} = crypto:generate_key(eddsa,ed25519),
    A = binary:encode_hex(PA), B = binary:encode_hex(PB),
    Common = #{swarm => binary:copy(<<"A">>,32),authority => A,epoch => 1,revision => 1},
    {A,B,KA,KB,
     parvi_swarm_control_protocol:new(KA,Common#{peers => #{B => [status_read]}}),
     parvi_swarm_control_protocol:new(KB,Common#{peers => #{A => [status_read]}})}.

otp_diagnostics_redact_keys_test() ->
    {_,_,_,_,P,_} = fixture(),
    Secret = <<"test-only-private-key-must-not-appear">>,
    Status = #{state => #{protocol => P#{private := Secret},private => Secret},
               message => Secret,reason => Secret,log => [Secret]},
    [?assertEqual(nomatch,binary:match(term_to_binary(Formatted),Secret)) || Formatted <-
        [parvi_swarm_control:format_status(Status),parvi_relay:format_status(Status)]].

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

p(F,Args) -> apply(parvi_swarm_control_protocol,F,Args).
body(Wire) -> json:decode(base64:decode(maps:get(<<"body">>,json:decode(Wire)))).
resign(Packet,{_,Private},Fun) -> p(seal,[Fun(body(Packet)),Private]).
raw_seal(Data,Private) ->
    Sig = crypto:sign(eddsa,none,[<<"parvi-swarm-control/v1:">>,Data],[Private,ed25519]),
    iolist_to_binary(json:encode(#{<<"body">> => base64:encode(Data),<<"signature">> => binary:encode_hex(Sig)})).
