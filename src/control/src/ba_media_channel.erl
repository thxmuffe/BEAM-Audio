%% Media routing inside the existing PeerConnection owner. No ICE/signalling here.
-module(ba_media_channel).
-export([request/3, event/2, down/2]).
-define(PC, 'Elixir.ExWebRTC.PeerConnection').
-define(PREFIX, "beamaudio-audio/v1/").

request({Action, Token, PeerNode}, {Owner, _}, S)
        when (Action =:= expect orelse Action =:= open),
             is_binary(Token), byte_size(Token) =:= 16, node(Owner) =:= node() ->
    Media = maps:get(media, S, #{}),
    case {ba_webrtc_dist:authorized(self(), PeerNode), maps:is_key(Token, Media)} of
        {{ok, PeerNode}, false} ->
            case channel(Action, Token, maps:get(pc, S)) of
                {ok, Ref} ->
                    Entry = #{owner => Owner, monitor => monitor(process, Owner),
                              ref => Ref, open => false},
                    {ok, S#{media => Media#{Token => Entry}}};
                Error -> {Error, S}
            end;
        _ -> {{error, unauthorized_or_duplicate}, S}
    end;
request({send, Token, Packet}, {Owner, _}, #{pc := PC} = S)
        when is_binary(Packet), byte_size(Packet) =< 16384 ->
    case maps:find(Token, maps:get(media, S, #{})) of
        {ok, #{owner := Owner, ref := Ref, open := true}} ->
            %% This bounds only the local PC mailbox, not the SCTP send buffer.
            case process_info(PC, message_queue_len) of
                {message_queue_len, N} when N < 256 ->
                    {?PC:send_data(PC, Ref, Packet, binary), S};
                _ -> {{error, busy}, S}
            end;
        _ -> {{error, media_not_open}, S}
    end;
request({close, Token}, {Owner, _}, S) ->
    case maps:find(Token, maps:get(media, S, #{})) of
        {ok, #{owner := Owner}} -> {ok, remove(Token, S)};
        _ -> {ok, S}
    end;
request(_, _, S) -> {{error, invalid_media_request}, S}.

channel(expect, _, _) -> {ok, undefined};
channel(open, Token, PC) ->
    case ?PC:create_data_channel(PC, <<?PREFIX, (binary:encode_hex(Token))/binary>>,
                                 [{ordered, false}, {max_retransmits, 0}]) of
        {ok, #{ref := Ref}} -> {ok, Ref};
        Error -> Error
    end.

event({data_channel, #{label := Label, ref := Ref}}, #{pc := PC} = S) ->
    %% Only an explicitly expected subscription may acquire an incoming channel.
    Matches = [Token || {Token, #{ref := undefined}} <- maps:to_list(maps:get(media, S, #{})),
                         Label =:= <<?PREFIX, (binary:encode_hex(Token))/binary>>],
    case Matches of
        [Token] ->
            Media = maps:get(media, S), Entry = maps:get(Token, Media),
            S#{media => Media#{Token => Entry#{ref := Ref}}};
        _ -> ?PC:close_data_channel(PC, Ref), S
    end;
event({data_channel_state_change, Ref, State}, S) ->
    case find(Ref, S) of
        {Token, Entry} when State =:= open ->
            notify(Token, Entry, open),
            S#{media => (maps:get(media, S))#{Token => Entry#{open := true}}};
        {Token, Entry} when State =:= closed ->
            notify(Token, Entry, closed), remove(Token, false, S);
        _ -> S
    end;
event({data, Ref, Packet}, S) when is_binary(Packet), byte_size(Packet) =< 16384 ->
    case find(Ref, S) of
        {Token, #{open := true} = Entry} -> notify(Token, Entry, {packet, Packet});
        _ -> ok
    end,
    S;
event(_, S) -> S.

down(Ref, S) ->
    lists:foldl(fun(Token, Acc) -> remove(Token, Acc) end, S,
        [Token || {Token, #{monitor := M}} <- maps:to_list(maps:get(media, S, #{})), M =:= Ref]).

find(Ref, S) ->
    case [{T, E} || {T, #{ref := R} = E} <- maps:to_list(maps:get(media, S, #{})), R =:= Ref] of
        [Match] -> Match;
        _ -> none
    end.
notify(Token, #{owner := Owner}, Event) -> Owner ! {media, self(), Token, Event}.
remove(Token, S) -> remove(Token, true, S).
remove(Token, Close, #{pc := PC} = S) ->
    Media = maps:get(media, S, #{}),
    case maps:take(Token, Media) of
        {#{ref := Ref, monitor := Monitor}, Rest} ->
            demonitor(Monitor, [flush]),
            case Close andalso Ref =/= undefined of
                true -> ?PC:close_data_channel(PC, Ref);
                false -> ok
            end,
            S#{media => Rest};
        error -> S
    end.
