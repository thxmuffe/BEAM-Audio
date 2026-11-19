%% The Session's request board. There is no Manager: every Device keeps its own
%% copy, syncs it on contact and passes new entries to its neighbours (gossip).
%% Entries are signed facts, so a copy from anyone can be checked; merging is a
%% union keyed by entry ID, so arrival order never matters. A request is open
%% until its Device holds the privilege, a grant holder declines it, or a day
%% passes.
-module(ba_session_board).
-export([new/0,request/5,decline/6,granted/6,merge/3,open/2,open_ids/4,entries/1,expire/2]).
-define(TTL,86400).
-define(SKEW,300).
-define(SEND,16).

new() -> #{}.

%% Signed by the requester; its join certificate proves it joined the Session.
request(Buffee,Device,Join,Wire,Private) ->
    entry(#{<<"kind">> => <<"request">>,<<"buffee">> => Buffee,<<"author">> => Device,
            <<"device">> => Device,<<"privilege">> => Wire,<<"join">> => Join},Private).
%% Signed by a grant holder; closes request Ref on every copy, for good.
decline(Buffee,Holder,Ref,Device,Wire,Private) -> answer(<<"declined">>,Buffee,Holder,Ref,Device,Wire,Private).
granted(Buffee,Holder,Ref,Device,Wire,Private) -> answer(<<"granted">>,Buffee,Holder,Ref,Device,Wire,Private).
answer(Kind,Buffee,Holder,Ref,Device,Wire,Private) ->
    entry(#{<<"kind">> => Kind,<<"buffee">> => Buffee,<<"author">> => Holder,
            <<"device">> => Device,<<"privilege">> => Wire,<<"ref">> => Ref},Private).
entry(Body,Private) ->
    Id = binary:encode_hex(crypto:strong_rand_bytes(16)),
    {Id,ba_buffee_passport:sign(Body#{<<"v">> => 1,<<"type">> => <<"board">>,<<"id">> => Id,
        <<"at">> => erlang:system_time(second)},Private)}.

%% Adds the valid entries not already known. Ctx: buffee, invitation (public
%% key) and policy (the signed statement; declines need its grant holders).
%% Returns the IDs that were new, for passing on to neighbours.
merge(Packets,Ctx,Board) when is_map(Packets) ->
    maps:fold(fun(Id,Packet,{New,Acc}) ->
        case maps:is_key(Id,Acc) of
            true -> {New,Acc};
            false -> case check(Id,Packet,Ctx) of
                {ok,Body} -> {[Id|New],Acc#{Id => {Body,Packet}}};
                error -> {New,Acc}
            end
        end
    end,{[],Board},Packets).
check(Id,Packet,#{buffee := Buffee,invitation := Invitation,policy := P}) ->
    try
        #{<<"body">> := Encoded} = ba_buffee_passport:decode(Packet),
        #{<<"author">> := Author} = ba_buffee_passport:decode(base64:decode(Encoded)),
        Body = ba_buffee_passport:verify(Packet,Author),
        #{<<"v">> := 1,<<"type">> := <<"board">>,<<"id">> := Id,<<"buffee">> := Buffee,
          <<"at">> := At,<<"kind">> := Kind,<<"device">> := Device,<<"privilege">> := Wire} = Body,
        Now = erlang:system_time(second),
        true = is_integer(At) andalso At > Now-?TTL andalso At =< Now+?SKEW,
        ok = ba_buffee_passport:permissions([Wire]),
        case Kind of
            <<"request">> ->
                ba_buffee_passport:exact(Body,[<<"v">>,<<"type">>,<<"id">>,<<"at">>,<<"kind">>,<<"buffee">>,
                    <<"author">>,<<"device">>,<<"privilege">>,<<"join">>]),
                Author = Device,
                true = ba_buffee_passport:joined(Buffee,Author,maps:get(<<"join">>,Body),Invitation);
            _ when Kind=:= <<"declined">>;Kind=:= <<"granted">> ->
                ba_buffee_passport:exact(Body,[<<"v">>,<<"type">>,<<"id">>,<<"at">>,<<"kind">>,<<"buffee">>,
                    <<"author">>,<<"device">>,<<"privilege">>,<<"ref">>]),
                true = ba_session_privileges:has(grant,Author,P)
        end,
        {ok,Body}
    catch _:_ -> error end.

%% Open requests as Device => [privilege wire names], judged by the statement.
open(Board,P) ->
    lists:foldl(fun({_,#{<<"device">> := D,<<"privilege">> := W}},Acc) ->
        Acc#{D => lists:usort([W|maps:get(D,Acc,[])])}
    end,#{},open_entries(Board,P)).
%% The open request IDs for one Device and privilege (to decline them).
open_ids(Board,P,Device,Wire) ->
    [Id || {Id,#{<<"device">> := D,<<"privilege">> := W}} <- open_entries(Board,P),D=:=Device,W=:=Wire].
open_entries(Board,P) ->
    Answered = [Ref || {#{<<"ref">> := Ref},_} <- maps:values(Board)],
    [{Id,B} || {Id,{#{<<"kind">> := <<"request">>,<<"device">> := D,<<"privilege">> := W}=B,_}} <- maps:to_list(Board),
        not lists:member(Id,Answered),not lists:member(W,held(D,P))].
held(D,#{<<"members">> := Members}) -> maps:get(<<"permissions">>,maps:get(D,Members,#{}),[]).

%% What to send a neighbour: the newest entries, bounded per message.
entries(Board) ->
    Newest = lists:sublist(lists:reverse(lists:keysort(1,
        [{maps:get(<<"at">>,B),Id,Packet} || {Id,{B,Packet}} <- maps:to_list(Board)])),?SEND),
    maps:from_list([{Id,Packet} || {_,Id,Packet} <- Newest]).
expire(Board,Now) -> maps:filter(fun(_,{#{<<"at">> := At},_}) -> At > Now-?TTL end,Board).
