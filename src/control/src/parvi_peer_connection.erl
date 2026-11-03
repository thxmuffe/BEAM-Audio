%% One Parvi peer connection, using ex_webrtc's public BEAM API directly.
%% The library owns the protocols; this worker owns our signalling lifecycle.
-module(parvi_peer_connection).
-behaviour(gen_server).
-export([start_link/3, signal/2, send_packet/2, close/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).
-define(PC, 'Elixir.ExWebRTC.PeerConnection').
-define(SD, 'Elixir.ExWebRTC.SessionDescription').
-define(ICE, 'Elixir.ExWebRTC.ICECandidate').

start_link(Owner, Initiator, Ice) -> gen_server:start_link(?MODULE, {Owner, Initiator, Ice}, []).
signal(Pid, Signal) -> gen_server:cast(Pid, {signal, Signal}).
send_packet(Pid, Packet) -> gen_server:call(Pid, {send, Packet}).
close(Pid) -> gen_server:cast(Pid, close).

init({Owner, Initiator, Ice}) ->
    process_flag(trap_exit, true),
    self() ! start,
    {ok, #{owner => Owner, initiator => Initiator, ice => Ice, pc => undefined,
           channel => undefined, session => undefined, ready => false, pending => []}}.

handle_info(start, #{initiator := true} = S) ->
    Next = new_connection(S#{session := binary:encode_hex(crypto:strong_rand_bytes(16))}),
    #{pc := PC, session := Session} = Next,
    {ok, #{ref := Ref}} = ?PC:create_data_channel(PC, <<"parvi-v1">>),
    {ok, Offer} = ?PC:create_offer(PC),
    ok = ?PC:set_local_description(PC, Offer),
    notify(Next, {signal, description(Session, Offer)}),
    {noreply, Next#{channel := Ref}};
handle_info(start, S) -> {noreply, S};
handle_info({ex_webrtc, PC, Event}, #{pc := PC} = S) -> {noreply, rtc_event(Event, S)};
handle_info(stop, S) -> {stop, normal, S};
handle_info({'EXIT', PC, _}, #{pc := PC} = S) ->
    notify(S, {ready, false}),
    {stop, normal, S};
handle_info(_, S) -> {noreply, S}.

handle_call({send, Packet}, _, #{ready := true, pc := PC, channel := Ref} = S)
        when byte_size(Packet) =< 131072 ->
    ok = ?PC:send_data(PC, Ref, Packet, string),
    {reply, ok, S};
handle_call({send, _}, _, S) -> {reply, {error, unavailable}, S}.

handle_cast(close, S) ->
    erlang:send_after(1000, self(), stop),
    {noreply, S};
handle_cast({signal, #{<<"kind">> := <<"offer">>, <<"sdp">> := SDP, <<"session">> := Session}},
        #{initiator := false} = S) ->
    close_connection(S),
    notify(S, {ready, false}),
    Next = new_connection(S#{session := Session, ready := false, channel := undefined}),
    #{pc := PC} = Next,
    ok = ?PC:set_remote_description(PC, ?SD:'__struct__'([{type, offer}, {sdp, SDP}])),
    {ok, Answer} = ?PC:create_answer(PC),
    ok = ?PC:set_local_description(PC, Answer),
    notify(Next, {signal, description(Session, Answer)}),
    {noreply, flush_candidates(Next)};
handle_cast({signal, #{<<"kind">> := <<"answer">>, <<"sdp">> := SDP, <<"session">> := Session}},
        #{initiator := true, session := Session, pc := PC} = S) ->
    ok = ?PC:set_remote_description(PC, ?SD:'__struct__'([{type, answer}, {sdp, SDP}])),
    {noreply, flush_candidates(S)};
handle_cast({signal, #{<<"kind">> := <<"candidate">>} = Signal},
        #{pc := PC, session := Session, pending := Pending} = S) ->
    case PC =:= undefined orelse ?PC:get_remote_description(PC) =:= nil of
        true -> {noreply, S#{pending := lists:sublist(Pending ++ [Signal], 128)}};
        false ->
            case maps:get(<<"session">>, Signal) =:= Session of
                true -> add_candidate(PC, Signal);
                false -> ok
            end,
            {noreply, S}
    end;
handle_cast(_, S) -> {noreply, S}.

terminate(_, S) -> close_connection(S).

new_connection(#{ice := Ice} = S) ->
    {ok, PC} = ?PC:start_link([{ice_servers, [#{urls => Ice}]}, {audio_codecs, []}, {video_codecs, []}]),
    S#{pc := PC}.

close_connection(#{pc := undefined}) -> ok;
close_connection(#{pc := PC}) ->
    case is_process_alive(PC) of true -> ?PC:close(PC); false -> ok end.

description(Session, #{type := Type, sdp := SDP}) ->
    #{<<"session">> => Session, <<"kind">> => atom_to_binary(Type), <<"sdp">> => SDP}.
notify(#{owner := Owner}, Event) -> Owner ! {parvi_direct, self(), Event}.

flush_candidates(#{pc := PC, session := Session, pending := Pending} = S) ->
    [add_candidate(PC, C) || C <- Pending, maps:get(<<"session">>, C) =:= Session],
    S#{pending := []}.
add_candidate(PC, #{<<"candidate">> := Candidate, <<"mid">> := Mid, <<"index">> := Index}) ->
    ?PC:add_ice_candidate(PC, ?ICE:'__struct__'([
        {candidate, Candidate}, {sdp_mid, Mid}, {sdp_m_line_index, Index}])).

rtc_event({ice_candidate, #{candidate := Candidate, sdp_mid := Mid, sdp_m_line_index := Index}},
        #{session := Session} = S) ->
    notify(S, {signal, #{<<"session">> => Session, <<"kind">> => <<"candidate">>,
        <<"candidate">> => Candidate, <<"mid">> => default(Mid, <<"0">>), <<"index">> => default(Index, 0)}}),
    S;
rtc_event({data_channel, #{label := <<"parvi-v1">>, ref := Ref}}, S) -> S#{channel := Ref};
rtc_event({data_channel_state_change, Ref, Status}, #{channel := Ref} = S) ->
    Ready = Status =:= open,
    notify(S, {ready, Ready}),
    S#{ready := Ready};
rtc_event({data, Ref, Packet}, #{channel := Ref, ready := true} = S) ->
    notify(S, {packet, Packet}), S;
rtc_event({connection_state_change, Status}, S)
        when Status =:= failed; Status =:= disconnected; Status =:= closed ->
    notify(S, {ready, false}), S#{ready := false};
rtc_event(_, S) -> S.

default(nil, Value) -> Value;
default(Value, _) -> Value.
