-module(ba_session_passport_tests).
-include_lib("eunit/include/eunit.hrl").
-define(URL,<<"ws://127.0.0.1:4000/relay/v1">>).
key() -> {Pub,Key}=crypto:generate_key(eddsa,ed25519),{binary:encode_hex(Pub),Key}.
invitation(Creator,Key) ->
    Nonce=binary:copy(<<"A">>,32),
    I=#{<<"v">>=>1,<<"type">>=><<"invitation">>,<<"name">>=><<"Test gathering">>,<<"authority">>=>Creator,
        <<"nonce">>=>Nonce,<<"session">>=>ba_session_passport:session_id(Creator,Nonce),
        <<"secret">>=>binary:copy(<<"B">>,64),<<"desks">>=>[?URL]},
    {I,ba_session_passport:sign(I,Key)}.

strict_decode_test() ->
    ?assertException(error,_,ba_session_passport:decode(<<"{\"x\":1,\"x\":2}">>)),
    ?assertException(error,_,ba_session_passport:decode(binary:copy(<<"x">>,32769))),
    ?assertException(error,_,ba_session_passport:parse_invitation(<<"beamaudio://session/v2?cookie=old">>)).

link_names_its_creator_test() ->
    {A,Key}=key(),{I,Packet}=invitation(A,Key),Link=ba_session_passport:invitation(Packet),
    ?assertMatch(<<"beamaudio://session/v5?",_/binary>>,Link),
    ?assertEqual({Packet,I},ba_session_passport:parse_invitation(Link)),
    %% The Session ID must follow from the signer's key: no squatting another ID.
    {B,BKey}=key(),
    Squat=ba_session_passport:invitation(ba_session_passport:sign(I#{<<"authority">> := B},BKey)),
    ?assertException(error,_,ba_session_passport:parse_invitation(Squat)),
    Forged=ba_session_passport:invitation(ba_session_passport:sign(I,BKey)),
    ?assertException(error,_,ba_session_passport:parse_invitation(Forged)),
    %% Tampering with the signature or the body is refused.
    #{query := Q}=uri_string:parse(Link),[{<<"ticket">>,Ticket}]=uri_string:dissect_query(Q),
    Raw=base64:decode(Ticket,#{mode => urlsafe,padding => false}),
    <<First,Rest/binary>>=Raw,N=byte_size(Raw)-1,<<Prefix:N/binary,Last>>=Raw,
    [?assertException(error,_,ba_session_passport:parse_invitation(<<"beamaudio://session/v5?ticket=",
        (base64:encode(Bad,#{mode => urlsafe,padding => false}))/binary>>))
        || Bad <- [<<(First bxor 1),Rest/binary>>,<<Prefix/binary,(Last bxor 1)>>]],
    %% Earlier formats named the inviter; they are no longer accepted.
    ?assertException(error,_,ba_session_passport:parse_invitation(binary:replace(Link,<<"/v5">>,<<"/v4">>))),
    ?assertException(error,_,ba_session_passport:parse_invitation(binary:replace(Link,<<"beamaudio:">>,<<"https:">>))).

%% v6: about 100 characters, same fields as v5 after parsing, no name or signature.
short_link_test() ->
    {A,_}=key(),Nonce=binary:encode_hex(crypto:strong_rand_bytes(16)),Secret=binary:encode_hex(crypto:strong_rand_bytes(16)),
    Default=ba_session_passport:default_desk(),
    I=#{<<"authority">>=>A,<<"nonce">>=>Nonce,<<"secret">>=>Secret,<<"desks">>=>[Default]},
    Link=ba_session_passport:link(I),
    ?assertMatch(<<"beamaudio://s/",_/binary>>,Link),
    ?assert(byte_size(Link) =< 104),
    {Link,B}=ba_session_passport:parse_invitation(Link),
    ?assertEqual(maps:merge(I,#{<<"v">>=>1,<<"type">>=><<"invitation">>,<<"name">>=><<"Session">>,
        <<"session">>=>ba_session_passport:session_id(A,Nonce)}),B),
    %% A non-default Reception travels in the link.
    {_,B2}=ba_session_passport:parse_invitation(ba_session_passport:link(I#{<<"desks">>:=[?URL]})),
    ?assertEqual([?URL],maps:get(<<"desks">>,B2)),
    %% A cut or wrong-version link is refused.
    ?assertException(error,_,ba_session_passport:parse_invitation(binary:part(Link,0,byte_size(Link)-8))),
    <<"beamaudio://s/",T/binary>>=Link,<<_,Rest/binary>>=base64:decode(T,#{mode => urlsafe,padding => false}),
    ?assertException(error,_,ba_session_passport:parse_invitation(<<"beamaudio://s/",(base64:encode(<<5,Rest/binary>>,#{mode => urlsafe,padding => false}))/binary>>)),
    %% The 128-bit secret works for the mailbox and the invitation key.
    ?assertEqual(32,byte_size(ba_session_passport:mailbox(Secret))).

mailbox_depends_on_the_secret_test() ->
    S1=binary:copy(<<"B">>,64),S2=binary:copy(<<"C">>,64),
    ?assertNotEqual(ba_session_passport:mailbox(S1),ba_session_passport:mailbox(S2)),
    ?assertEqual(32,byte_size(ba_session_passport:mailbox(S1))).

%% Holding the link lets a Device sign its own join certificate; anyone checks
%% it against the public invitation key. It names one Device in one Session.
join_certificate_test() ->
    Session=binary:copy(<<"A">>,32),A=binary:copy(<<"B">>,64),B=binary:copy(<<"C">>,64),
    {Public,Private}=ba_session_passport:invitation_key(binary:copy(<<"5">>,32)),
    ?assertEqual({Public,Private},ba_session_passport:invitation_key(binary:copy(<<"5">>,32))),
    {Other,_}=ba_session_passport:invitation_key(binary:copy(<<"6">>,32)),
    Join=ba_session_passport:join(Session,A,Private),
    ?assert(ba_session_passport:joined(Session,A,Join,Public)),
    ?assertNot(ba_session_passport:joined(Session,B,Join,Public)),
    ?assertNot(ba_session_passport:joined(binary:copy(<<"D">>,32),A,Join,Public)),
    ?assertNot(ba_session_passport:joined(Session,A,Join,Other)),
    ?assertNot(ba_session_passport:joined(Session,A,<<"00">>,Public)).

genesis_and_participant_permissions_test() ->
    {A,Key}=key(),{I,_}=invitation(A,Key),
    G=ba_session_passport:genesis(I,[<<"status_read">>]),
    ?assertEqual(ok,ba_session_passport:policy(G)),?assertEqual(0,maps:get(<<"revision">>,G)),
    ?assert(ba_session_privileges:has(grant,A,G)),
    ?assertException(error,_,ba_session_passport:policy(G#{<<"removed">> := [A]})),
    ?assertException(error,_,ba_session_passport:permissions([<<"spawn">>])),
    ?assertException(error,_,ba_session_passport:permissions([<<"status_read">>,<<"status_read">>])).

delegation_chain_reaches_the_creator_test() ->
    {A,AKey}=key(),{B,BKey}=key(),{C,CKey}=key(),{I,_}=invitation(A,AKey),
    Session=maps:get(<<"session">>,I),G=ba_session_passport:genesis(I,[]),
    Grant=ba_session_privileges:wire(grant),
    P=G#{<<"revision">> := 4,<<"members">> := (maps:get(<<"members">>,G))#{B=>#{<<"permissions">>=>[Grant]},C=>#{<<"permissions">>=>[Grant]}}},
    AB=ba_session_passport:sign(ba_session_passport:delegation(Session,A,B,2),AKey),
    BC=ba_session_passport:sign(ba_session_passport:delegation(Session,B,C,4),BKey),
    St=#{<<"name">>=><<"N">>,<<"policy">>=>P,<<"delegations">>=>#{B=>AB,C=>BC}},
    ?assertEqual(0,ba_session_passport:grant_revision(A,A,St)),
    ?assertEqual(2,ba_session_passport:grant_revision(B,A,St)),
    ?assertEqual(4,ba_session_passport:grant_revision(C,A,St)),
    %% A certificate outside the creator's chain, or for another Session, fails.
    {X,XKey}=key(),
    Rogue=ba_session_passport:sign(ba_session_passport:delegation(Session,X,C,4),XKey),
    ?assertException(error,_,ba_session_passport:grant_revision(C,A,St#{<<"delegations">> := #{C=>Rogue}})),
    Other=ba_session_passport:sign(ba_session_passport:delegation(binary:copy(<<"F">>,32),A,B,2),AKey),
    ?assertException(error,_,ba_session_passport:grant_revision(B,A,St#{<<"delegations">> := #{B=>Other}})),
    %% Cycles never reach the creator.
    CB=ba_session_passport:sign(ba_session_passport:delegation(Session,C,B,3),CKey),
    ?assertException(error,_,ba_session_passport:grant_revision(B,A,St#{<<"delegations">> := #{B=>CB,C=>BC}})).

statement_round_trip_test() ->
    {A,Key}=key(),{I,_}=invitation(A,Key),G=ba_session_passport:genesis(I,[]),
    St=#{<<"name">>=><<"N">>,<<"policy">>=>G#{<<"revision">> := 1},<<"delegations">>=>#{}},
    Packet=ba_session_passport:sign(St,Key),
    ?assertEqual(St,ba_session_passport:statement(Packet,A)),
    {B,_}=key(),?assertException(error,_,ba_session_passport:statement(Packet,B)).



%% Equal revisions with different content converge: whichever a Device holds,
%% exactly one of the two statements wins, and the same one everywhere.
policy_order_converges_test() ->
    Cur=#{<<"revision">>=>2},P1 = <<"statement one">>,P2 = <<"statement two">>,
    S1=#{policy=>Cur,signed=>P1},S2=#{policy=>Cur,signed=>P2},
    ?assertEqual(newer,ba_session_membership:order(3,P2,S1)),
    ?assertEqual(older,ba_session_membership:order(1,P2,S1)),
    ?assertEqual(same,ba_session_membership:order(2,P1,S1)),
    ?assertEqual(newer,ba_session_membership:order(2,P1,#{policy=>Cur,signed=>undefined})),
    Winner=case crypto:hash(sha256,P1) < crypto:hash(sha256,P2) of true -> P1;false -> P2 end,
    ?assertEqual(lists:sort([newer,older]),lists:sort([ba_session_membership:order(2,P2,S1),ba_session_membership:order(2,P1,S2)])),
    ?assertEqual(same,ba_session_membership:order(2,Winner,#{policy=>Cur,signed=>Winner})),
    Loser=hd([P1,P2]--[Winner]),
    ?assertEqual(newer,ba_session_membership:order(2,Winner,#{policy=>Cur,signed=>Loser})),
    ?assertEqual(older,ba_session_membership:order(2,Loser,#{policy=>Cur,signed=>Winner})).
