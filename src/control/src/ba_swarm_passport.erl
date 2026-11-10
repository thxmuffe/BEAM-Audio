%% Signed credentials for the current gathering, separate from live operation/session grants.
-module(ba_swarm_passport).
-export([sign/2,verify/2,decode/1,exact/2,passport/4,policy/1,runtime_policy/2,
         invitation/1,parse_invitation/1,urls/1,route/2,permissions/1]).
-define(DOMAIN,<<"parvi-swarm-membership/v1:">>).
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
passport(Packet,Authority,Device,Swarm) ->
    P = verify(Packet,Authority),
    exact(P,[<<"v">>,<<"type">>,<<"swarm">>,<<"authority">>,<<"device">>,<<"membership">>,<<"epoch">>]),
    #{<<"v">> := 1,<<"type">> := <<"passport">>,<<"swarm">> := Swarm,
      <<"authority">> := Authority,<<"device">> := Device} = P,
    true = hex(Swarm,32),true = hex(Device,64),true = hex(maps:get(<<"membership">>,P),32),
    positive(maps:get(<<"epoch">>,P)),P.
policy(P) ->
    exact(P,[<<"v">>,<<"type">>,<<"swarm">>,<<"authority">>,<<"director">>,<<"epoch">>,<<"revision">>,<<"members">>]),
    #{<<"v">> := 1,<<"type">> := <<"policy">>,<<"members">> := Members} = P,
    true = hex(maps:get(<<"swarm">>,P),32),
    true = is_map(Members) andalso map_size(Members) > 0 andalso map_size(Members) =< 16,
    [begin Id = maps:get(K,P),true = hex(Id,64),true = maps:is_key(Id,Members) end || K <- [<<"authority">>,<<"director">>]],
    positive(maps:get(<<"epoch">>,P)),positive(maps:get(<<"revision">>,P)),
    maps:foreach(fun(Id,M) -> true = hex(Id,64),exact(M,[<<"membership">>,<<"permissions">>]),
        true = hex(maps:get(<<"membership">>,M),32),permissions(maps:get(<<"permissions">>,M)) end,Members),ok.
runtime_policy(P,Self) ->
    ok = policy(P),Members = maps:get(<<"members">>,P),true = maps:is_key(Self,Members),
    #{swarm => maps:get(<<"swarm">>,P),authority => maps:get(<<"authority">>,P),
      director => maps:get(<<"director">>,P),epoch => maps:get(<<"epoch">>,P),revision => maps:get(<<"revision">>,P),
      peers => maps:map(fun(_,M) -> lists:sort([permission(X) || X <- maps:get(<<"permissions">>,M)]) end,maps:remove(Self,Members))}.
permissions(L) ->
    true = is_list(L) andalso length(L) =< 7 andalso lists:usort(L) =:= L,
    [permission(P) || P <- L],ok.
permission(<<"capabilities_read">>) -> capabilities_read;
permission(<<"job_offer">>) -> job_offer;
permission(<<"status_read">>) -> status_read;
permission(<<"stream_read">>) -> stream_read;
permission(<<"stream_subscribe">>) -> stream_subscribe;
permission(<<"time_read">>) -> time_read;
permission(<<"offset_write">>) -> offset_write.
invitation(Packet) -> <<"parvi://swarm/v3?",(uri_string:compose_query([{<<"ticket">>,base64:encode(Packet)}]))/binary>>.
parse_invitation(Link) when is_binary(Link),byte_size(Link) =< 32768 ->
    #{scheme := <<"parvi">>,host := <<"swarm">>,path := <<"/v3">>,query := Q} = U = uri_string:parse(Link),
    true = map_size(U) =:= 4,[{<<"ticket">>,B64}] = uri_string:dissect_query(Q),Packet = base64:decode(B64),
    E = decode(Packet),Body = decode(base64:decode(maps:get(<<"body">>,E))),Authority = maps:get(<<"authority">>,Body),
    Body = verify(Packet,Authority),
    exact(Body,[<<"v">>,<<"type">>,<<"swarm">>,<<"authority">>,<<"invite">>,<<"secret">>,<<"expires">>,<<"desks">>,<<"route">>,<<"name">>]),
    #{<<"v">> := 1,<<"type">> := <<"invitation">>} = Body,
    true = hex(maps:get(<<"swarm">>,Body),32),true = hex(maps:get(<<"invite">>,Body),32),
    true = hex(maps:get(<<"secret">>,Body),64),
    Name = maps:get(<<"name">>,Body),true = is_binary(Name) andalso byte_size(Name)>0 andalso byte_size(Name)=<128,
    %% Legacy numeric expiry remains signed metadata, not a current restriction.
    case maps:get(<<"expires">>,Body) of null -> ok;Expiry -> positive(Expiry) end,
    urls(maps:get(<<"desks">>,Body)),route(maps:get(<<"route">>,Body),maps:get(<<"desks">>,Body)),{Packet,Body}.
urls(L) ->
    true = is_list(L) andalso length(L) > 0 andalso length(L) =< 4,
    true = lists:usort(L) =:= lists:sort(L),true = lists:all(fun ba_relay:valid_url/1,L),ok.
route(#{<<"desk">> := URL,<<"mailbox">> := Cap} = R,URLs) ->
    exact(R,[<<"desk">>,<<"mailbox">>]),true = lists:member(URL,URLs),true = hex(Cap,32),ok.
exact(M,Keys) -> true = is_map(M),true = lists:sort(maps:keys(M)) =:= lists:sort(Keys),ok.
positive(N) -> true = is_integer(N) andalso N > 0 andalso N =< 9007199254740991,ok.
hex(B,N) -> ba_swarm_job:hex(B,N).
decode(Data) when is_binary(Data),byte_size(Data) =< 32768 ->
    {V,_,<<>>} = json:decode(Data,{0,undefined},#{
        object_start => fun({D,_}) -> true = D < 5,{D+1,#{}} end,
        object_push => fun(K,X,{D,M}) -> false = maps:is_key(K,M),true = map_size(M) < 32,{D,M#{K => X}} end,
        object_finish => fun({_,M},Old) -> {M,Old} end,
        array_start => fun({D,_}) -> true = D < 5,{D+1,[]} end,
        array_push => fun(X,{D,L}) -> true = length(L) < 32,{D,[X|L]} end,
        array_finish => fun({_,L},Old) -> {lists:reverse(L),Old} end,
        integer => fun(B) -> true = byte_size(B) =< 16,binary_to_integer(B) end}),V.
