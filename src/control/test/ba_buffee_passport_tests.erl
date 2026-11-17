-module(ba_buffee_passport_tests).
-include_lib("eunit/include/eunit.hrl").
-define(URL,<<"ws://127.0.0.1:4000/relay/v1">>).
key() -> {Pub,Key}=crypto:generate_key(eddsa,ed25519),{binary:encode_hex(Pub),Key}.
invitation(Creator,Key) ->
    Nonce=binary:copy(<<"A">>,32),
    I=#{<<"v">>=>1,<<"type">>=><<"invitation">>,<<"name">>=><<"Test gathering">>,<<"authority">>=>Creator,
        <<"nonce">>=>Nonce,<<"buffee">>=>ba_buffee_passport:session_id(Creator,Nonce),
        <<"secret">>=>binary:copy(<<"B">>,64),<<"desks">>=>[?URL]},
    {I,ba_buffee_passport:sign(I,Key)}.

strict_decode_test() ->
    ?assertException(error,_,ba_buffee_passport:decode(<<"{\"x\":1,\"x\":2}">>)),
    ?assertException(error,_,ba_buffee_passport:decode(binary:copy(<<"x">>,32769))),
    ?assertException(error,_,ba_buffee_passport:parse_invitation(<<"beamaudio://buffee/v2?cookie=old">>)).

link_names_its_creator_test() ->
    {A,Key}=key(),{I,Packet}=invitation(A,Key),Link=ba_buffee_passport:invitation(Packet),
    ?assertMatch(<<"beamaudio://session/v5?",_/binary>>,Link),
    ?assertEqual({Packet,I},ba_buffee_passport:parse_invitation(Link)),
    %% The Session ID must follow from the signer's key: no squatting another ID.
    {B,BKey}=key(),
    Squat=ba_buffee_passport:invitation(ba_buffee_passport:sign(I#{<<"authority">> := B},BKey)),
    ?assertException(error,_,ba_buffee_passport:parse_invitation(Squat)),
    Forged=ba_buffee_passport:invitation(ba_buffee_passport:sign(I,BKey)),
    ?assertException(error,_,ba_buffee_passport:parse_invitation(Forged)),
    %% Tampering with the signature or the body is refused.
    #{query := Q}=uri_string:parse(Link),[{<<"ticket">>,Ticket}]=uri_string:dissect_query(Q),
    Raw=base64:decode(Ticket,#{mode => urlsafe,padding => false}),
    <<First,Rest/binary>>=Raw,N=byte_size(Raw)-1,<<Prefix:N/binary,Last>>=Raw,
    [?assertException(error,_,ba_buffee_passport:parse_invitation(<<"beamaudio://session/v5?ticket=",
        (base64:encode(Bad,#{mode => urlsafe,padding => false}))/binary>>))
        || Bad <- [<<(First bxor 1),Rest/binary>>,<<Prefix/binary,(Last bxor 1)>>]],
    %% Earlier formats named the inviter; they are no longer accepted.
    ?assertException(error,_,ba_buffee_passport:parse_invitation(binary:replace(Link,<<"/v5">>,<<"/v4">>))),
    ?assertException(error,_,ba_buffee_passport:parse_invitation(binary:replace(Link,<<"beamaudio:">>,<<"https:">>))).

mailbox_and_proof_depend_on_the_secret_test() ->
    S1=binary:copy(<<"B">>,64),S2=binary:copy(<<"C">>,64),
    ?assertNotEqual(ba_buffee_passport:mailbox(S1),ba_buffee_passport:mailbox(S2)),
    ?assertEqual(32,byte_size(ba_buffee_passport:mailbox(S1))),
    P=[<<"joiner">>,<<"X">>,<<"A">>,<<"B">>],
    ?assertNotEqual(ba_buffee_passport:proof(S1,P),ba_buffee_passport:proof(S2,P)),
    ?assertNotEqual(ba_buffee_passport:proof(S1,P),ba_buffee_passport:proof(S1,[<<"joiner">>,<<"X">>,<<"B">>,<<"A">>])).

genesis_and_participant_permissions_test() ->
    {A,Key}=key(),{I,_}=invitation(A,Key),B=binary:copy(<<"B">>,64),
    G=ba_buffee_passport:genesis(I,[<<"status_read">>]),
    ?assertEqual(ok,ba_buffee_passport:policy(G)),?assertEqual(0,maps:get(<<"revision">>,G)),
    ?assert(ba_session_privileges:has(grant,A,G)),
    ?assertEqual(#{B=>[status_read]},maps:get(peers,ba_buffee_passport:runtime_policy(G,A,#{A=>[],B=>[<<"status_read">>]}))),
    ?assertException(error,_,ba_buffee_passport:policy(G#{<<"removed">> := [A]})),
    ?assertException(error,_,ba_buffee_passport:permissions([<<"spawn">>])),
    ?assertException(error,_,ba_buffee_passport:permissions([<<"status_read">>,<<"status_read">>])).

delegation_chain_reaches_the_creator_test() ->
    {A,AKey}=key(),{B,BKey}=key(),{C,CKey}=key(),{I,_}=invitation(A,AKey),
    Buffee=maps:get(<<"buffee">>,I),G=ba_buffee_passport:genesis(I,[]),
    Grant=ba_session_privileges:wire(grant),
    P=G#{<<"revision">> := 4,<<"members">> := (maps:get(<<"members">>,G))#{B=>#{<<"permissions">>=>[Grant]},C=>#{<<"permissions">>=>[Grant]}}},
    AB=ba_buffee_passport:sign(ba_buffee_passport:delegation(Buffee,A,B,2),AKey),
    BC=ba_buffee_passport:sign(ba_buffee_passport:delegation(Buffee,B,C,4),BKey),
    St=#{<<"name">>=><<"N">>,<<"policy">>=>P,<<"delegations">>=>#{B=>AB,C=>BC}},
    ?assertEqual(0,ba_buffee_passport:grant_revision(A,A,St)),
    ?assertEqual(2,ba_buffee_passport:grant_revision(B,A,St)),
    ?assertEqual(4,ba_buffee_passport:grant_revision(C,A,St)),
    %% A certificate outside the creator's chain, or for another Session, fails.
    {X,XKey}=key(),
    Rogue=ba_buffee_passport:sign(ba_buffee_passport:delegation(Buffee,X,C,4),XKey),
    ?assertException(error,_,ba_buffee_passport:grant_revision(C,A,St#{<<"delegations">> := #{C=>Rogue}})),
    Other=ba_buffee_passport:sign(ba_buffee_passport:delegation(binary:copy(<<"F">>,32),A,B,2),AKey),
    ?assertException(error,_,ba_buffee_passport:grant_revision(B,A,St#{<<"delegations">> := #{B=>Other}})),
    %% Cycles never reach the creator.
    CB=ba_buffee_passport:sign(ba_buffee_passport:delegation(Buffee,C,B,3),CKey),
    ?assertException(error,_,ba_buffee_passport:grant_revision(B,A,St#{<<"delegations">> := #{B=>CB,C=>BC}})).

statement_round_trip_test() ->
    {A,Key}=key(),{I,_}=invitation(A,Key),G=ba_buffee_passport:genesis(I,[]),
    St=#{<<"name">>=><<"N">>,<<"policy">>=>G#{<<"revision">> := 1},<<"delegations">>=>#{}},
    Packet=ba_buffee_passport:sign(St,Key),
    ?assertEqual(St,ba_buffee_passport:statement(Packet,A)),
    {B,_}=key(),?assertException(error,_,ba_buffee_passport:statement(Packet,B)).

stale_handshake_response_is_rejected_test() ->
    {A,Key}=key(),B=binary:copy(<<"B">>,64),Buffee=binary:copy(<<"A">>,32),Req=binary:copy(<<"A">>,32),
    S=#{id=>B,buffee=>Buffee,rejected=>0,participants=>#{},outgoing=>#{},pending=>#{}},
    Body=#{<<"v">>=>1,<<"type">>=><<"welcome">>,<<"from">>=>A,<<"to">>=>B,
        <<"buffee">>=>Buffee,<<"request">>=>Req,<<"payload">>=>#{<<"policy">>=>null}},
    Packet=ba_buffee_passport:sign(Body,Key),
    ?assertEqual({noreply,S#{rejected:=1}},ba_buffee_membership:handle_info({desk_delivery,unused,A,Packet},S)).

non_participant_cannot_end_the_session_test() ->
    {A,Key}=key(),B=binary:copy(<<"B">>,64),Buffee=binary:copy(<<"A">>,32),
    S=#{id=>B,buffee=>Buffee,rejected=>0,participants=>#{},outgoing=>#{},pending=>#{},pairs=>#{}},
    Body=#{<<"v">>=>1,<<"type">>=><<"ended">>,<<"from">>=>A,<<"to">>=>B,
        <<"buffee">>=>Buffee,<<"request">>=>Buffee,<<"payload">>=>#{<<"pair">>=>Buffee}},
    Packet=ba_buffee_passport:sign(Body,Key),
    ?assertEqual({noreply,S#{rejected:=1}},ba_buffee_membership:handle_info({desk_delivery,unused,A,Packet},S)).
