-module(ba_buffee_passport_tests).
-include_lib("eunit/include/eunit.hrl").
fixture() ->
    {Pub,Key}=crypto:generate_key(eddsa,ed25519),A=binary:encode_hex(Pub),
    B=binary:copy(<<"B">>,64),Buffee=binary:copy(<<"A">>,32),
    Pass=#{<<"v">>=>1,<<"type">>=><<"passport">>,<<"buffee">>=>Buffee,
           <<"authority">>=>A,<<"device">>=>B,<<"membership">>=>Buffee,<<"epoch">>=>1},
    {A,B,Buffee,Key,Pass}.
passport_binding_test() ->
    {A,B,Buffee,Key,P}=fixture(),Packet=ba_buffee_passport:sign(P,Key),
    ?assertEqual(P,ba_buffee_passport:passport(Packet,A,B,Buffee)),
    ?assertException(error,_,ba_buffee_passport:passport(Packet,A,A,Buffee)),
    ?assertException(error,_,ba_buffee_passport:passport(Packet,A,B,binary:copy(<<"C">>,32))),
    ?assertException(error,_,ba_buffee_passport:verify(Packet,B)),
    ?assertException(error,_,ba_buffee_passport:passport(ba_buffee_passport:sign(P#{<<"epoch">>:=0},Key),A,B,Buffee)).
strict_decode_test() ->
    ?assertException(error,_,ba_buffee_passport:decode(<<"{\"x\":1,\"x\":2}">>)),
    ?assertException(error,_,ba_buffee_passport:decode(binary:copy(<<"x">>,32769))),
    ?assertException(error,_,ba_buffee_passport:parse_invitation(<<"beamaudio://buffee/v2?cookie=old">>)).
policy_separates_permission_test() ->
    {A,B,Buffee,_,_}=fixture(),
    P=#{<<"v">>=>1,<<"type">>=><<"policy">>,<<"buffee">>=>Buffee,<<"authority">>=>A,
        <<"manager">>=>A,<<"epoch">>=>1,<<"revision">>=>1,
        <<"members">>=>#{A=>#{<<"membership">>=>Buffee,<<"permissions">>=>[]},
                         B=>#{<<"membership">>=>Buffee,<<"permissions">>=>[]}}},
    ?assertEqual(#{B=>[]},maps:get(peers,ba_buffee_passport:runtime_policy(P,A))),
    ?assertException(error,_,ba_buffee_passport:permissions([<<"spawn">>])),
    ?assertException(error,_,ba_buffee_passport:permissions([<<"status_read">>,<<"status_read">>])).
invitation_scope_without_expiry_test() ->
    {A,_,Buffee,Key,_}=fixture(),URL = <<"ws://127.0.0.1:4000/relay/v1">>,
    I=#{<<"v">>=>1,<<"type">>=><<"invitation">>,<<"name">>=><<"Test gathering">>,<<"authority">>=>A,<<"buffee">>=>Buffee,
        <<"invite">>=>Buffee,<<"secret">>=>binary:copy(<<"A">>,64),
        <<"expires">>=>erlang:system_time(second)+60,<<"desks">>=>[URL],
        <<"route">>=>#{<<"desk">>=>URL,<<"mailbox">>=>Buffee}},
    Packet=ba_buffee_passport:sign(I,Key),Link=ba_buffee_passport:invitation(Packet),
    ?assertEqual({Packet,I},ba_buffee_passport:parse_invitation(Link)),
    ?assertMatch(<<"beamaudio://session/v4?",_/binary>>,Link),
    #{query := Q}=uri_string:parse(Link),[{<<"ticket">>,Ticket}]=uri_string:dissect_query(Q),
    <<First,Rest/binary>>=base64:decode(Ticket,#{mode => urlsafe,padding => false}),
    Bad=base64:encode(<<(First bxor 1),Rest/binary>>,#{mode => urlsafe,padding => false}),
    ?assertException(error,_,ba_buffee_passport:parse_invitation(<<"beamaudio://session/v4?ticket=",Bad/binary>>)),
    Raw=base64:decode(Ticket,#{mode => urlsafe,padding => false}),
    N=byte_size(Raw)-1,<<Prefix:N/binary,Last>>=Raw,
    BadBody=base64:encode(<<Prefix/binary,(Last bxor 1)>>,#{mode => urlsafe,padding => false}),
    ?assertException(error,_,ba_buffee_passport:parse_invitation(<<"beamaudio://session/v4?ticket=",BadBody/binary>>)),
    ?assertException(error,_,ba_buffee_passport:parse_invitation(<<"beamaudio://session/v4?ticket=AA">>)),
    ?assertException(error,_,ba_buffee_passport:parse_invitation(binary:copy(<<"x">>,32769))),
    Legacy = <<"beamaudio://buffee/v3?",(uri_string:compose_query([{<<"ticket">>,base64:encode(Packet)}]))/binary>>,
    ?assertEqual({Packet,I},ba_buffee_passport:parse_invitation(Legacy)),
    ?assert(byte_size(Link)<byte_size(Legacy)*0.75),
    io:format("Invitation lengths: legacy=~B compact=~B~n",[byte_size(Legacy),byte_size(Link)]),
    ?assertEqual({Packet,I},ba_buffee_passport:parse_invitation(binary:replace(Legacy,<<"beamaudio:">>,<<"beamaudio:">>))),
    ?assertException(error,_,ba_buffee_passport:parse_invitation(binary:replace(Link,<<"beamaudio:">>,<<"https:">>))),
    Expired=ba_buffee_passport:invitation(ba_buffee_passport:sign(I#{<<"expires">>:=1},Key)),
    ?assertMatch({_,#{<<"expires">> := 1}},ba_buffee_passport:parse_invitation(Expired)),
    Unlimited=ba_buffee_passport:invitation(ba_buffee_passport:sign(I#{<<"expires">>:=null},Key)),
    ?assertMatch({_,#{<<"expires">> := null}},ba_buffee_passport:parse_invitation(Unlimited)),
    ?assertException(error,_,ba_buffee_passport:route(#{<<"desk">>=><<"ws://127.0.0.1:99/relay/v1">>,<<"mailbox">>=>Buffee},[URL])).
stale_authority_response_test() ->
    {A,B,Buffee,Key,_}=fixture(),Req=binary:copy(<<"A">>,32),Nonce=binary:copy(<<"A">>,64),
    S=#{role=>member,id=>B,buffee=>Buffee,authority=>A,rejected=>0,
        request=>#{id=>Req,nonce=>Nonce,deadline=>erlang:monotonic_time(millisecond)-1}},
    Body=#{<<"v">>=>1,<<"type">>=><<"denied">>,<<"from">>=>A,<<"to">>=>B,
        <<"buffee">>=>Buffee,<<"request">>=>Req,<<"payload">>=>#{<<"nonce">>=>Nonce,<<"reason">>=><<"revoked">>}},
    Packet=ba_buffee_passport:sign(Body,Key),
    ?assertEqual({noreply,S#{rejected:=1}},ba_buffee_membership:handle_info({desk_delivery,unused,A,Packet},S)).

old_signed_departure_cannot_evict_a_new_admission_test() ->
    {APub,_}=crypto:generate_key(eddsa,ed25519),A=binary:encode_hex(APub),
    {BPub,BKey}=crypto:generate_key(eddsa,ed25519),B=binary:encode_hex(BPub),
    Buffee=binary:copy(<<"A">>,32),Old=binary:copy(<<"B">>,32),New=binary:copy(<<"C">>,32),
    S=#{role=>authority,id=>A,buffee=>Buffee,rejected=>0,routes=>#{},invitations=>#{},
        policy=>#{<<"members">>=>#{B=>#{<<"membership">>=>New}}}},
    Body=#{<<"v">>=>1,<<"type">>=><<"leave">>,<<"from">>=>B,<<"to">>=>A,
        <<"buffee">>=>Buffee,<<"request">>=>Old,<<"payload">>=>#{<<"membership">>=>Old}},
    Packet=ba_buffee_passport:sign(Body,BKey),
    ?assertEqual({noreply,S#{rejected:=1}},ba_buffee_membership:handle_info({desk_delivery,unused,B,Packet},S)).
