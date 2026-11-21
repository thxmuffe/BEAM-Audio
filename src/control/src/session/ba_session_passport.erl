%% Signed Session documents: the creator's permanent invitation link, the
%% versioned privilege policy and `grant` delegation certificates. The module
%% keeps its historical name; there is no separate passport credential.
-module(ba_session_passport).
-export([default_desk/0,sign/2,verify/2,decode/1,exact/2,session_id/2,mailbox/1,
         invitation/1,link/1,parse_invitation/1,genesis/2,policy/1,statement/2,delegation/4,
         grant_revision/3,urls/1,permissions/1,permission/1,
         invitation_key/1,join/3,joined/4,envelope_key/1,seal_envelope/3,open_envelope/3]).
-define(DOMAIN,<<"beamaudio-session-membership/v1:">>).
-define(MAILBOX,<<"beamaudio-session-mailbox/v1:">>).
sign(Body,Private) ->
    Data = iolist_to_binary(json:encode(Body)),
    Sig = crypto:sign(eddsa,none,[?DOMAIN,Data],[Private,ed25519]),
    Packet = iolist_to_binary(json:encode(#{<<"body">> => base64:encode(Data),<<"signature">> => binary:encode_hex(Sig)})),
    true = byte_size(Packet) =< 32768,Packet.
verify(Packet,Signer) when is_binary(Packet),byte_size(Packet) =< 32768 ->
    true = ba_hex:valid(Signer,64),E = decode(Packet),exact(E,[<<"body">>,<<"signature">>]),
    Sig = maps:get(<<"signature">>,E),true = ba_hex:valid(Sig,128),Data = base64:decode(maps:get(<<"body">>,E)),
    true = crypto:verify(eddsa,none,[?DOMAIN,Data],binary:decode_hex(Sig),[binary:decode_hex(Signer),ed25519]),
    decode(Data).

%% The Session ID names its creator: anyone can check it without a registry.
session_id(Creator,Nonce) ->
    true = ba_hex:valid(Creator,64),true = ba_hex:valid(Nonce,32),
    binary:part(binary:encode_hex(crypto:hash(sha256,[binary:decode_hex(Creator),binary:decode_hex(Nonce)])),0,32).
%% Every participant advertises this mailbox; Reception sees it, not the secret.
mailbox(Secret) ->
    true = secret(Secret),
    binary:part(binary:encode_hex(crypto:hash(sha256,[?MAILBOX,Secret])),0,32).
%% The invitation key is derived from the link's secret, so links already
%% shared keep working. A joining Device signs its own ID with it; any Device
%% checks that join certificate against the public invitation key, per request.
-define(INVITATION_KEY,<<"beamaudio-session-invitation-key/v1:">>).
-define(JOIN,<<"beamaudio-session-join/v1:">>).
%% End-to-end key for Session messages: every link holder has it, Reception
%% does not. Signatures inside still prove who wrote each message.
-define(ENVELOPE,<<"beamaudio-session-envelope/v1:">>).
envelope_key(Secret) -> true = secret(Secret),crypto:hash(sha256,[?ENVELOPE,Secret]).
seal_envelope(Key,Session,Plain) ->
    Nonce = crypto:strong_rand_bytes(12),
    {Cipher,Tag} = crypto:crypto_one_time_aead(chacha20_poly1305,Key,Nonce,Plain,Session,true),
    base64:encode(<<Nonce/binary,Tag/binary,Cipher/binary>>).
open_envelope(Key,Session,Sealed) ->
    <<Nonce:12/binary,Tag:16/binary,Cipher/binary>> = base64:decode(Sealed),
    case crypto:crypto_one_time_aead(chacha20_poly1305,Key,Nonce,Cipher,Session,Tag,false) of
        error -> error(envelope_rejected);
        Plain -> Plain
    end.
invitation_key(Secret) ->
    true = secret(Secret),
    {Public,Private} = crypto:generate_key(eddsa,ed25519,crypto:hash(sha256,[?INVITATION_KEY,Secret])),
    {binary:encode_hex(Public),Private}.
join(Session,Device,Private) ->
    true = ba_hex:valid(Session,32) andalso ba_hex:valid(Device,64),
    binary:encode_hex(crypto:sign(eddsa,none,[?JOIN,Session,Device],[Private,ed25519])).
joined(Session,Device,Join,Invitation) ->
    ba_hex:valid(Join,128) andalso ba_hex:valid(Invitation,64) andalso
        crypto:verify(eddsa,none,[?JOIN,Session,Device],binary:decode_hex(Join),[binary:decode_hex(Invitation),ed25519]).
%% v6 links carry a 128-bit secret; v5 links carried 256 bits.
secret(Secret) -> ba_hex:valid(Secret,32) orelse ba_hex:valid(Secret,64).

%% v5 transports the exact signed JSON bytes plus the raw Ed25519 signature.
invitation(Packet) ->
    E=decode(Packet),exact(E,[<<"body">>,<<"signature">>]),
    Data=base64:decode(maps:get(<<"body">>,E)),
    Sig=binary:decode_hex(maps:get(<<"signature">>,E)),64=byte_size(Sig),
    Ticket=base64:encode(<<Sig/binary,Data/binary>>,#{mode => urlsafe,padding => false}),
    <<"beamaudio://session/v5?ticket=",Ticket/binary>>.
%% v6: the shortest link that still identifies the Session and its creator.
%% Raw bytes, base64url: version 6, creator key (32), nonce (16), secret (16),
%% then the Reception addresses separated by newlines, left out when the only
%% one is the default. No signature and no name: joiners verify every change
%% against the creator key, and learn the name from the signed policy.
-define(V6,<<"beamaudio://s/">>).
link(#{<<"authority">> := Creator,<<"nonce">> := Nonce,<<"secret">> := Secret,<<"desks">> := Desks}) ->
    true = ba_hex:valid(Secret,32),urls(Desks),
    Tail = case Desks =:= [default_desk()] of true -> <<>>;false -> iolist_to_binary(lists:join(<<"\n">>,Desks)) end,
    Bytes = <<6,(binary:decode_hex(Creator))/binary,(binary:decode_hex(Nonce))/binary,(binary:decode_hex(Secret))/binary,Tail/binary>>,
    <<?V6/binary,(base64:encode(Bytes,#{mode => urlsafe,padding => false}))/binary>>.
%% The one default Reception: ba_core.app.src (default_reception_desk_url).
default_desk() -> {ok,URL}=ba_settings:app(default_reception_desk_url),URL.
%% A v6 link parses to the same fields as v5, so everything after parsing is shared.
parse_invitation(<<"beamaudio://s/",Ticket/binary>>=Link) when byte_size(Link) =< 4096 ->
    <<6,Creator:32/binary,Nonce:16/binary,Secret:16/binary,Tail/binary>> = base64:decode(Ticket,#{mode => urlsafe,padding => false}),
    Desks = case Tail of <<>> -> [default_desk()];_ -> binary:split(Tail,<<"\n">>,[global]) end,
    urls(Desks),
    [C,N] = [binary:encode_hex(X) || X <- [Creator,Nonce]],
    Body = #{<<"v">> => 1,<<"type">> => <<"invitation">>,<<"session">> => session_id(C,N),<<"authority">> => C,
             <<"nonce">> => N,<<"secret">> => binary:encode_hex(Secret),<<"desks">> => Desks,<<"name">> => <<"Session">>},
    {Link,Body};
%% v5 links still parse, so a Session saved by an older build cannot stop a Device.
parse_invitation(Link) when is_binary(Link),byte_size(Link) =< 32768 ->
    #{scheme := <<"beamaudio">>,host := <<"session">>,path := <<"/v5">>,query := Q} = U = uri_string:parse(Link),
    true = map_size(U) =:= 4,[{<<"ticket">>,B64}] = uri_string:dissect_query(Q),
    <<Sig:64/binary,Data/binary>> = base64:decode(B64,#{mode => urlsafe,padding => false}),
    Packet=iolist_to_binary(json:encode(#{<<"body">> => base64:encode(Data),<<"signature">> => binary:encode_hex(Sig)})),
    Body = verify(Packet,maps:get(<<"authority">>,decode(Data))),
    exact(Body,[<<"v">>,<<"type">>,<<"session">>,<<"authority">>,<<"nonce">>,<<"secret">>,<<"desks">>,<<"name">>]),
    #{<<"v">> := 1,<<"type">> := <<"invitation">>,<<"session">> := Session,<<"authority">> := Creator,<<"nonce">> := Nonce} = Body,
    Session = session_id(Creator,Nonce),true = ba_hex:valid(maps:get(<<"secret">>,Body),64),
    Name = maps:get(<<"name">>,Body),true = is_binary(Name) andalso byte_size(Name)>0 andalso byte_size(Name)=<128,
    urls(maps:get(<<"desks">>,Body)),{Packet,Body}.

%% Revision 0 follows from the link alone: the creator holds every privilege.
genesis(Invitation,Defaults) ->
    Creator=maps:get(<<"authority">>,Invitation),
    #{<<"v">> => 2,<<"type">> => <<"policy">>,<<"session">> => maps:get(<<"session">>,Invitation),
      <<"authority">> => Creator,<<"manager">> => Creator,<<"revision">> => 0,
      <<"members">> => #{Creator => #{<<"permissions">> => ba_session_privileges:creator(Defaults)}},
      <<"removed">> => []}.
policy(P) ->
    exact(P,[<<"v">>,<<"type">>,<<"session">>,<<"authority">>,<<"manager">>,<<"revision">>,<<"members">>,<<"removed">>]),
    #{<<"v">> := 2,<<"type">> := <<"policy">>,<<"members">> := Members,<<"removed">> := Removed} = P,
    true = ba_hex:valid(maps:get(<<"session">>,P),32),
    true = is_map(Members) andalso map_size(Members) =< 16,
    [true = ba_hex:valid(maps:get(K,P),64) || K <- [<<"authority">>,<<"manager">>]],
    natural(maps:get(<<"revision">>,P)),
    true = is_list(Removed) andalso length(Removed) =< 31 andalso lists:usort(Removed) =:= Removed,
    true = lists:all(fun(D) -> ba_hex:valid(D,64) andalso not maps:is_key(D,Members) end,Removed),
    maps:foreach(fun(Id,M) -> true = ba_hex:valid(Id,64),exact(M,[<<"permissions">>]),
        permissions(maps:get(<<"permissions">>,M)) end,Members),ok.
%% A signed policy statement and the delegation certificates of its grant holders.
statement(Packet,Signer) ->
    St = verify(Packet,Signer),
    %% The Response time is a Session setting like the name (absent: the default).
    exact(St,[<<"name">>,<<"policy">>,<<"delegations">>]++
        [K || K <- [<<"response_ms">>,<<"response_auto">>],maps:is_key(K,St)]),
    case maps:find(<<"response_ms">>,St) of {ok,Ms} -> ok = ba_response_time:valid(Ms);error -> ok end,
    true = is_boolean(maps:get(<<"response_auto">>,St,true)),
    Name = maps:get(<<"name">>,St),true = is_binary(Name) andalso byte_size(Name)>0 andalso byte_size(Name)=<128,
    ok = policy(maps:get(<<"policy">>,St)),
    D = maps:get(<<"delegations">>,St),true = is_map(D) andalso map_size(D) =< 16,St.
%% Issued when `grant` is given; verifiable without the issuer being present.
delegation(Session,Issuer,Grantee,Revision) ->
    #{<<"v">> => 1,<<"type">> => <<"delegation">>,<<"session">> => Session,
      <<"issuer">> => Issuer,<<"grantee">> => Grantee,<<"revision">> => Revision}.
%% Revision at which Signer received `grant`, following certificates to the creator.
grant_revision(Signer,Creator,#{<<"policy">> := P,<<"delegations">> := D}) ->
    chain(Signer,Creator,maps:get(<<"session">>,P),D,[]).
chain(Creator,Creator,_,_,_) -> 0;
chain(Grantee,Creator,Session,D,Seen) ->
    false = lists:member(Grantee,Seen),true = length(Seen) < 16,
    Cert = maps:get(Grantee,D),
    Issuer = maps:get(<<"issuer">>,decode(base64:decode(maps:get(<<"body">>,decode(Cert))))),
    Body = verify(Cert,Issuer),
    exact(Body,[<<"v">>,<<"type">>,<<"session">>,<<"issuer">>,<<"grantee">>,<<"revision">>]),
    #{<<"v">> := 1,<<"type">> := <<"delegation">>,<<"session">> := Session,<<"grantee">> := Grantee,<<"revision">> := R} = Body,
    true = is_integer(R) andalso R > 0,
    _ = chain(Issuer,Creator,Session,D,[Grantee|Seen]),R.

permissions(L) ->
    true = is_list(L) andalso length(L) =< 10 andalso lists:usort(L) =:= L,
    [permission(P) || P <- L],ok.
permission(<<"capabilities_read">>) -> capabilities_read;
permission(<<"status_read">>) -> status_read;
permission(<<"stream_read">>) -> stream_read;
permission(<<"stream_subscribe">>) -> stream_subscribe;
permission(<<"owner">>) -> owner;
permission(<<"end_session">>) -> end_session;
permission(<<"stream_publish">>) -> stream_publish.
urls(L) ->
    true = is_list(L) andalso length(L) > 0 andalso length(L) =< 4,
    true = lists:usort(L) =:= lists:sort(L),true = lists:all(fun ba_relay:valid_url/1,L),ok.
exact(M,Keys) -> true = is_map(M),true = lists:sort(maps:keys(M)) =:= lists:sort(Keys),ok.
natural(N) -> true = is_integer(N) andalso N >= 0 andalso N =< 9007199254740991,ok.
decode(Data) when is_binary(Data),byte_size(Data) =< 32768 ->
    {V,_,<<>>} = json:decode(Data,{0,undefined},#{
        object_start => fun({D,_}) -> true = D < 5,{D+1,#{}} end,
        object_push => fun(K,X,{D,M}) -> false = maps:is_key(K,M),true = map_size(M) < 32,{D,M#{K => X}} end,
        object_finish => fun({_,M},Old) -> {M,Old} end,
        array_start => fun({D,_}) -> true = D < 5,{D+1,[]} end,
        array_push => fun(X,{D,L}) -> true = length(L) < 32,{D,[X|L]} end,
        array_finish => fun({_,L},Old) -> {lists:reverse(L),Old} end,
        integer => fun(B) -> true = byte_size(B) =< 16,binary_to_integer(B) end}),V.
