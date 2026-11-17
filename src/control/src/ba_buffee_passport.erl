%% Signed Session documents: the creator's permanent invitation link, the
%% versioned privilege policy and `grant` delegation certificates. The module
%% keeps its historical name; there is no separate passport credential.
-module(ba_buffee_passport).
-export([sign/2,verify/2,decode/1,exact/2,session_id/2,mailbox/1,proof/2,
         invitation/1,parse_invitation/1,genesis/2,policy/1,statement/2,delegation/4,
         grant_revision/3,runtime_policy/3,urls/1,route/2,permissions/1]).
-define(DOMAIN,<<"beamaudio-buffee-membership/v1:">>).
-define(MAILBOX,<<"beamaudio-session-mailbox/v1:">>).
sign(Body,Private) ->
    Data = iolist_to_binary(json:encode(Body)),
    Sig = crypto:sign(eddsa,none,[?DOMAIN,Data],[Private,ed25519]),
    Packet = iolist_to_binary(json:encode(#{<<"body">> => base64:encode(Data),<<"signature">> => binary:encode_hex(Sig)})),
    true = byte_size(Packet) =< 32768,Packet.
verify(Packet,Signer) when is_binary(Packet),byte_size(Packet) =< 32768 ->
    true = hex(Signer,64),E = decode(Packet),exact(E,[<<"body">>,<<"signature">>]),
    Sig = maps:get(<<"signature">>,E),true = hex(Sig,128),Data = base64:decode(maps:get(<<"body">>,E)),
    true = crypto:verify(eddsa,none,[?DOMAIN,Data],binary:decode_hex(Sig),[binary:decode_hex(Signer),ed25519]),
    decode(Data).

%% The Session ID names its creator: anyone can check it without a registry.
session_id(Creator,Nonce) ->
    true = hex(Creator,64),true = hex(Nonce,32),
    binary:part(binary:encode_hex(crypto:hash(sha256,[binary:decode_hex(Creator),binary:decode_hex(Nonce)])),0,32).
%% Every participant advertises this mailbox; Reception sees it, not the secret.
mailbox(Secret) ->
    true = hex(Secret,64),
    binary:part(binary:encode_hex(crypto:hash(sha256,[?MAILBOX,Secret])),0,32).
%% Proof of holding the link, bound to direction, challenge and both Devices.
proof(Secret,Parts) ->
    true = hex(Secret,64),
    binary:encode_hex(crypto:mac(hmac,sha256,Secret,lists:join(<<":">>,Parts))).

%% v5 transports the exact signed JSON bytes plus the raw Ed25519 signature.
invitation(Packet) ->
    E=decode(Packet),exact(E,[<<"body">>,<<"signature">>]),
    Data=base64:decode(maps:get(<<"body">>,E)),
    Sig=binary:decode_hex(maps:get(<<"signature">>,E)),64=byte_size(Sig),
    Ticket=base64:encode(<<Sig/binary,Data/binary>>,#{mode => urlsafe,padding => false}),
    <<"beamaudio://session/v5?ticket=",Ticket/binary>>.
%% Only v5 links are accepted; earlier formats named the inviter, not the creator.
parse_invitation(Link) when is_binary(Link),byte_size(Link) =< 32768 ->
    #{scheme := <<"beamaudio">>,host := <<"session">>,path := <<"/v5">>,query := Q} = U = uri_string:parse(Link),
    true = map_size(U) =:= 4,[{<<"ticket">>,B64}] = uri_string:dissect_query(Q),
    <<Sig:64/binary,Data/binary>> = base64:decode(B64,#{mode => urlsafe,padding => false}),
    Packet=iolist_to_binary(json:encode(#{<<"body">> => base64:encode(Data),<<"signature">> => binary:encode_hex(Sig)})),
    Body = verify(Packet,maps:get(<<"authority">>,decode(Data))),
    exact(Body,[<<"v">>,<<"type">>,<<"buffee">>,<<"authority">>,<<"nonce">>,<<"secret">>,<<"desks">>,<<"name">>]),
    #{<<"v">> := 1,<<"type">> := <<"invitation">>,<<"buffee">> := Buffee,<<"authority">> := Creator,<<"nonce">> := Nonce} = Body,
    Buffee = session_id(Creator,Nonce),true = hex(maps:get(<<"secret">>,Body),64),
    Name = maps:get(<<"name">>,Body),true = is_binary(Name) andalso byte_size(Name)>0 andalso byte_size(Name)=<128,
    urls(maps:get(<<"desks">>,Body)),{Packet,Body}.

%% Revision 0 follows from the link alone: the creator holds every privilege.
genesis(Invitation,Defaults) ->
    Creator=maps:get(<<"authority">>,Invitation),
    #{<<"v">> => 2,<<"type">> => <<"policy">>,<<"buffee">> => maps:get(<<"buffee">>,Invitation),
      <<"authority">> => Creator,<<"manager">> => Creator,<<"revision">> => 0,
      <<"members">> => #{Creator => #{<<"permissions">> => ba_session_privileges:creator(Defaults)}},
      <<"removed">> => []}.
policy(P) ->
    exact(P,[<<"v">>,<<"type">>,<<"buffee">>,<<"authority">>,<<"manager">>,<<"revision">>,<<"members">>,<<"removed">>]),
    #{<<"v">> := 2,<<"type">> := <<"policy">>,<<"members">> := Members,<<"removed">> := Removed} = P,
    true = hex(maps:get(<<"buffee">>,P),32),
    true = is_map(Members) andalso map_size(Members) =< 16,
    [true = hex(maps:get(K,P),64) || K <- [<<"authority">>,<<"manager">>]],
    natural(maps:get(<<"revision">>,P)),
    true = is_list(Removed) andalso length(Removed) =< 31 andalso lists:usort(Removed) =:= Removed,
    true = lists:all(fun(D) -> hex(D,64) andalso not maps:is_key(D,Members) end,Removed),
    maps:foreach(fun(Id,M) -> true = hex(Id,64),exact(M,[<<"permissions">>]),
        permissions(maps:get(<<"permissions">>,M)) end,Members),ok.
%% A signed policy statement and the delegation certificates of its grant holders.
statement(Packet,Signer) ->
    St = verify(Packet,Signer),
    exact(St,[<<"name">>,<<"policy">>,<<"delegations">>]),
    Name = maps:get(<<"name">>,St),true = is_binary(Name) andalso byte_size(Name)>0 andalso byte_size(Name)=<128,
    ok = policy(maps:get(<<"policy">>,St)),
    D = maps:get(<<"delegations">>,St),true = is_map(D) andalso map_size(D) =< 16,St.
%% Issued when `grant` is given; verifiable without the issuer being present.
delegation(Buffee,Issuer,Grantee,Revision) ->
    #{<<"v">> => 1,<<"type">> => <<"delegation">>,<<"buffee">> => Buffee,
      <<"issuer">> => Issuer,<<"grantee">> => Grantee,<<"revision">> => Revision}.
%% Revision at which Signer received `grant`, following certificates to the creator.
grant_revision(Signer,Creator,#{<<"policy">> := P,<<"delegations">> := D}) ->
    chain(Signer,Creator,maps:get(<<"buffee">>,P),D,[]).
chain(Creator,Creator,_,_,_) -> 0;
chain(Grantee,Creator,Buffee,D,Seen) ->
    false = lists:member(Grantee,Seen),true = length(Seen) < 16,
    Cert = maps:get(Grantee,D),
    Issuer = maps:get(<<"issuer">>,decode(base64:decode(maps:get(<<"body">>,decode(Cert))))),
    Body = verify(Cert,Issuer),
    exact(Body,[<<"v">>,<<"type">>,<<"buffee">>,<<"issuer">>,<<"grantee">>,<<"revision">>]),
    #{<<"v">> := 1,<<"type">> := <<"delegation">>,<<"buffee">> := Buffee,<<"grantee">> := Grantee,<<"revision">> := R} = Body,
    true = is_integer(R) andalso R > 0,
    _ = chain(Issuer,Creator,Buffee,D,[Grantee|Seen]),R.

%% Peers: participant => permissions, already resolved against the policy.
%% Control envelopes count revisions from 1; the link's own revision 0 is 1 there.
runtime_policy(P,Self,Peers) ->
    ok = policy(P),
    #{buffee => maps:get(<<"buffee">>,P),authority => maps:get(<<"authority">>,P),
      manager => maps:get(<<"manager">>,P),epoch => 1,revision => maps:get(<<"revision">>,P)+1,
      peers => maps:map(fun(_,Perms) -> lists:sort([permission(X) || X <- Perms]) end,maps:remove(Self,Peers))}.
permissions(L) ->
    true = is_list(L) andalso length(L) =< 10 andalso lists:usort(L) =:= L,
    [permission(P) || P <- L],ok.
permission(<<"capabilities_read">>) -> capabilities_read;
permission(<<"job_offer">>) -> job_offer;
permission(<<"status_read">>) -> status_read;
permission(<<"stream_read">>) -> stream_read;
permission(<<"stream_subscribe">>) -> stream_subscribe;
permission(<<"time_read">>) -> time_read;
permission(<<"offset_write">>) -> offset_write;
permission(<<"owner">>) -> owner;
permission(<<"end_session">>) -> end_session;
permission(<<"stream_publish">>) -> stream_publish.
urls(L) ->
    true = is_list(L) andalso length(L) > 0 andalso length(L) =< 4,
    true = lists:usort(L) =:= lists:sort(L),true = lists:all(fun ba_relay:valid_url/1,L),ok.
route(#{<<"desk">> := URL,<<"mailbox">> := Cap} = R,URLs) ->
    exact(R,[<<"desk">>,<<"mailbox">>]),true = lists:member(URL,URLs),true = hex(Cap,32),ok.
exact(M,Keys) -> true = is_map(M),true = lists:sort(maps:keys(M)) =:= lists:sort(Keys),ok.
natural(N) -> true = is_integer(N) andalso N >= 0 andalso N =< 9007199254740991,ok.
hex(B,N) -> ba_buffee_job:hex(B,N).
decode(Data) when is_binary(Data),byte_size(Data) =< 32768 ->
    {V,_,<<>>} = json:decode(Data,{0,undefined},#{
        object_start => fun({D,_}) -> true = D < 5,{D+1,#{}} end,
        object_push => fun(K,X,{D,M}) -> false = maps:is_key(K,M),true = map_size(M) < 32,{D,M#{K => X}} end,
        object_finish => fun({_,M},Old) -> {M,Old} end,
        array_start => fun({D,_}) -> true = D < 5,{D+1,[]} end,
        array_push => fun(X,{D,L}) -> true = length(L) < 32,{D,[X|L]} end,
        array_finish => fun({_,L},Old) -> {lists:reverse(L),Old} end,
        integer => fun(B) -> true = byte_size(B) =< 16,binary_to_integer(B) end}),V.
