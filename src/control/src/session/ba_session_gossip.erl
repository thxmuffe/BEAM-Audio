%% Signed notes passed from neighbour to neighbour so they reach the whole
%% Session without anyone knowing everyone (epidemic broadcast). A note is
%% checked on each hop, forwarded once (by ID), and expires after two minutes.
%% Kinds: on_air, measured Response time batches, and playback state changes.
-module(ba_session_gossip).
-export([note/6,note/7,check/3,expire/2]).
-define(TTL,120).
-define(SKEW,300).

%% Signed by its author, with its join certificate.
note(Session,Device,Join,Kind,Fields,Private) ->
    Id = binary:encode_hex(crypto:strong_rand_bytes(16)),
    note(Id,Session,Device,Join,Kind,Fields,Private).

note(Id,Session,Device,Join,Kind,Fields,Private) ->
    ok = fields(Kind,Fields),
    {Id,ba_session_passport:sign(Fields#{<<"v">> => 1,<<"type">> => <<"note">>,<<"id">> => Id,<<"kind">> => Kind,
        <<"session">> => Session,<<"author">> => Device,<<"join">> => Join,<<"at">> => erlang:system_time(second)},Private)}.

check(Id,Packet,#{session := Session,invitation := Invitation}) ->
    try
        #{<<"body">> := Encoded} = ba_session_passport:decode(Packet),
        #{<<"author">> := Author} = ba_session_passport:decode(base64:decode(Encoded)),
        Body = ba_session_passport:verify(Packet,Author),
        Base = [<<"v">>,<<"type">>,<<"id">>,<<"kind">>,<<"session">>,<<"author">>,<<"join">>,<<"at">>],
        ok = fields(maps:get(<<"kind">>,Body),maps:without(Base,Body)),
        #{<<"v">> := 1,<<"type">> := <<"note">>,<<"id">> := Id,<<"session">> := Session,
          <<"join">> := Join,<<"at">> := At} = Body,
        Now = erlang:system_time(second),
        true = is_integer(At) andalso At > Now-?TTL andalso At =< Now+?SKEW,
        true = ba_session_passport:joined(Session,Author,Join,Invitation),
        {ok,Body}
    catch _:_ -> error end.

fields(<<"on_air">>,F) when map_size(F)=:=0 -> ok;
fields(<<"response">>,#{<<"count">> := N,<<"sum_ns">> := Sum}=F) when map_size(F)=:=2,
    is_integer(N),N>0,N=<1000000,is_integer(Sum),Sum>=0,Sum=<9007199254740991 -> ok;
fields(<<"playback">>,#{<<"playing">> := Playing,<<"failed">> := Failed,
    <<"started">> := Started,<<"revision">> := Rev}=F) when map_size(F)=:=4,
    is_boolean(Playing),is_boolean(Failed),is_boolean(Started),is_integer(Rev),Rev>0,
    Rev=<9007199254740991, (not Started orelse Playing) -> ok.

%% Seen note IDs (Id => arrival second) older than a note's life are forgotten.
expire(Seen,Now) -> maps:filter(fun(_,At) -> At > Now-2*?TTL end,Seen).
