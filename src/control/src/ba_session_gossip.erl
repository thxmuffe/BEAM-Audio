%% Signed notes passed from neighbour to neighbour so they reach the whole
%% Session without anyone knowing everyone (epidemic broadcast). A note is
%% checked on each hop, forwarded once (by ID), and expires after two minutes.
-module(ba_session_gossip).
-export([note/5,check/3,expire/2]).
-define(TTL,120).
-define(SKEW,300).
-define(KINDS,[<<"on_air">>]).

%% Signed by its author, with its join certificate.
note(Buffee,Device,Join,Kind,Private) ->
    true = lists:member(Kind,?KINDS),
    Id = binary:encode_hex(crypto:strong_rand_bytes(16)),
    {Id,ba_buffee_passport:sign(#{<<"v">> => 1,<<"type">> => <<"note">>,<<"id">> => Id,<<"kind">> => Kind,
        <<"buffee">> => Buffee,<<"author">> => Device,<<"join">> => Join,<<"at">> => erlang:system_time(second)},Private)}.

check(Id,Packet,#{buffee := Buffee,invitation := Invitation}) ->
    try
        #{<<"body">> := Encoded} = ba_buffee_passport:decode(Packet),
        #{<<"author">> := Author} = ba_buffee_passport:decode(base64:decode(Encoded)),
        Body = ba_buffee_passport:verify(Packet,Author),
        ba_buffee_passport:exact(Body,[<<"v">>,<<"type">>,<<"id">>,<<"kind">>,<<"buffee">>,<<"author">>,<<"join">>,<<"at">>]),
        #{<<"v">> := 1,<<"type">> := <<"note">>,<<"id">> := Id,<<"buffee">> := Buffee,<<"kind">> := Kind,
          <<"join">> := Join,<<"at">> := At} = Body,
        true = lists:member(Kind,?KINDS),
        Now = erlang:system_time(second),
        true = is_integer(At) andalso At > Now-?TTL andalso At =< Now+?SKEW,
        true = ba_buffee_passport:joined(Buffee,Author,Join,Invitation),
        {ok,Body}
    catch _:_ -> error end.

%% Seen note IDs (Id => arrival second) older than a note's life are forgotten.
expire(Seen,Now) -> maps:filter(fun(_,At) -> At > Now-2*?TTL end,Seen).
