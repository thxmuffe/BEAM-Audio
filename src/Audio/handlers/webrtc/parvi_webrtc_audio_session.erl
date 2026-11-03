%% One supervised endpoint per side. SDP/ICE use the authorized BEAM peer;
%% media uses DTLS-SRTP, and iPhone NetEq owns the comparison's adaptive playout.
-module(parvi_webrtc_audio_session).
-behaviour(gen_statem).
-export([start_link/1, init/1, callback_mode/0, handle_event/4, terminate/3]).
-define(PC, 'Elixir.ExWebRTC.PeerConnection').
-define(SD, 'Elixir.ExWebRTC.SessionDescription').
-define(ICE, 'Elixir.ExWebRTC.ICECandidate').
start_link(Args) -> gen_statem:start_link(?MODULE, Args, []).
callback_mode() -> handle_event_function.
init({receiver, Owner}) ->
    monitor(process, Owner), {ok, idle, #{role => receiver, owner => Owner, pending_ice => []}};
init({provider, Source, Peer, #{selector := all} = Request, Descriptor}) ->
    monitor(process, Source), monitor(process, Peer),
    {ok, PC} = ?PC:start_link([{ice_servers, ice()}, {video_codecs, []}]),
    monitor(process, PC),
    Track = 'Elixir.ExWebRTC.MediaStreamTrack':new(audio),
    {ok, _} = ?PC:add_track(PC, Track),
    {ok, negotiating, #{role => provider, source => Source, peer => Peer, descriptor => Descriptor,
        pc => PC, track => maps:get(id,Track), sequence => rand:uniform(65536)-1,
        timestamp => rand:uniform(4294967296)-1,
        timing_observations => maps:get(timing_observations,Request,false), pending_ice => []}, timeout()};
init(_) -> {stop, unsupported_audio_comparison_request}.

handle_event({call, From}, {open, Source, Request}, idle, D) ->
    monitor(process, Source), Id = gen_server:send_request(Source, {subscribe,Request#{timing_observations => true}}),
    {next_state, opening, D#{source => Source, pending => Id, caller => From}, timeout()};
handle_event(info, Message, opening, #{pending := Id} = D) ->
    case gen_server:check_response(Message,Id) of
        {reply, {ok, Peer, Descriptor}} ->
            monitor(process, Peer),
            {next_state, accepted, maps:without([pending,caller],D#{peer => Peer, descriptor => Descriptor}),
                [{reply,maps:get(caller,D),{ok,self(),Descriptor}} | timeout()]};
        no_reply -> keep_state_and_data;
        Other -> {stop, {open_failed,Other}, D}
    end;
handle_event({call, From}, {listen, Consumer}, _, #{role := receiver} = D) ->
    {keep_state,D#{consumer => Consumer},[{reply,From,ok}]};
handle_event({call, From}, ready, accepted, #{role := receiver} = D) ->
    case os:getenv("PARVI_WEBRTC_AUDIO_PORT") of
        false -> {stop_and_reply, normal, [{reply,From,{error,<<"Native WebRTC audio is unavailable; update the iPhone app.">>}}],D};
        PortText ->
            {ok, Socket} = gen_tcp:connect({127,0,0,1},list_to_integer(PortText),
                [binary,{packet,4},{active,once},{packet_size,131072},{send_timeout,1000},{send_timeout_close,true}],2000),
            ok = send_native(Socket,#{op => <<"prepare">>, ice_servers => ice()}),
            erlang:send_after(1000,self(),stats),
            Next = request_clock(D#{socket => Socket, caller => From}),
            {next_state,negotiating,Next,timeout()}
    end;
handle_event({call, From}, {playback, Action}, active, #{socket := Socket} = D) ->
    Op = case Action of start -> <<"play">>; stop -> <<"pause">> end,
    Reply = send_native(Socket,#{op => Op}),
    {keep_state,D,[{reply,From,Reply}]};
handle_event({call, From}, status, State, D) ->
    {keep_state_and_data,[{reply,From,#{state => State, backend => parvi_audio_stream_handler_webrtc:info(),
        statistics => maps:get(statistics,D,#{})}}]};
handle_event({call, From}, {minimum_playout_delay, Delay}, active, #{socket := Socket} = D)
        when not is_map_key(delay_caller,D),
             (Delay =:= automatic orelse (is_integer(Delay) andalso Delay >= 0 andalso Delay =< 10000)) ->
    Value = case Delay of automatic -> null; _ -> Delay end,
    Id = erlang:unique_integer([positive,monotonic]),
    ok = send_native(Socket,#{op => <<"minimum_delay">>, delay_ms => Value, request_id => Id}),
    {keep_state,D#{delay_caller => {From,Id}},[{{timeout,minimum_delay},2000,command_timeout}]};
handle_event({call, From}, _, _, _) -> {keep_state_and_data,[{reply,From,{error,invalid_state}}]};
handle_event(cast, {encoded, Source, #{sample_position := Position} = Timing, Packet}, active,
             #{role := provider, source := Source, pc := PC, track := Track,
               sequence := Seq, timestamp := Origin} = D) ->
    Time = (Origin + Position) band 16#ffffffff,
    RTP = 'Elixir.ExRTP.Packet':new(Packet,[{sequence_number,Seq},{timestamp,Time},{marker,Seq =:= 0}]),
    ok = ?PC:send_rtp(PC,Track,RTP),
    %% One anchor per second plus segment/validity changes, separate from RTP. Every receiver
    %% can relate its RTP position to the same source capture timeline.
    Presentation = maps:get(presentation,Timing,#{}),
    Marker = {maps:get(capture_segment,Timing,0),maps:get(continuous,Timing,false),
              maps:get(revision,Presentation,undefined)},
    Changed = Marker =/= maps:get(last_timeline_marker,D,undefined),
    Next = case maps:get(timing_observations,D) andalso
                (Changed orelse Position - maps:get(last_timeline_position,D,Position-48000) >= 48000) of
        true ->
            signal(maps:get(peer,D),#{<<"event">> => <<"timeline">>,
                <<"timeline">> => Timing#{rtp_timestamp => Time}}),
            D#{last_timeline_position => Position,last_timeline_marker => Marker};
        false -> D
    end,
    {keep_state,Next#{sequence := (Seq+1) band 16#ffff}};
handle_event(cast, {signal, Peer, #{<<"event">> := <<"offer">>, <<"sdp">> := SDP}}, _,
             #{role := provider, peer := Peer, pc := PC} = D) ->
    ok = ?PC:set_remote_description(PC,?SD:from_json(#{<<"type">> => <<"offer">>,<<"sdp">> => SDP})),
    {ok,Answer} = ?PC:create_answer(PC), ok = ?PC:set_local_description(PC,Answer),
    signal(Peer,#{<<"event">> => <<"answer">>, <<"sdp">> => maps:get(sdp,Answer)}),
    [add_ice(PC,C) || C <- lists:reverse(maps:get(pending_ice,D))],
    {keep_state,D#{remote_ready => true,pending_ice := []}};
handle_event(cast, {signal, Peer, #{<<"event">> := <<"candidate">>,<<"candidate">> := C}}, _,
             #{role := provider, peer := Peer, pc := PC} = D) ->
    case maps:get(remote_ready,D,false) of
        true -> ok = add_ice(PC,C), keep_state_and_data;
        false -> {keep_state,D#{pending_ice := [C|maps:get(pending_ice,D)]}}
    end;
handle_event(cast, {signal, Peer, #{<<"event">> := <<"timeline">>, <<"timeline">> := Timeline}}, _,
             #{role := receiver, peer := Peer} = D) ->
    {keep_state,D#{source_timeline => Timeline}};
handle_event(cast, {signal, Peer, #{<<"event">> := Event} = Message}, _,
             #{role := receiver, peer := Peer, socket := Socket} = D) ->
    Op = case Event of <<"answer">> -> <<"answer">>; <<"candidate">> -> <<"candidate">> end,
    ok = send_native(Socket,(maps:remove(<<"event">>,Message))#{op => Op}), {keep_state,D};
handle_event(info, {tcp, Socket, Bytes}, State, #{socket := Socket, peer := Peer} = D) ->
    ok = inet:setopts(Socket,[{active,once}]), M = json:decode(Bytes),
    case maps:get(<<"event">>,M) of
        <<"offer">> -> signal(Peer,M), keep_state_and_data;
        <<"candidate">> -> signal(Peer,M), keep_state_and_data;
        <<"connected">> when State =:= negotiating ->
            %% Keep normal adaptive playout until Erlang supplies a minimum.
            ok = send_native(Socket,#{op => <<"minimum_delay">>, delay_ms => null, request_id => 0}),
            {next_state,active,maps:remove(caller,D),[{reply,maps:get(caller,D),ok}]};
        <<"minimum_delay">> ->
            case {maps:get(delay_caller,D,undefined),maps:get(<<"request_id">>,M,undefined)} of
                {{From,Id},Id} ->
                    Reply = case maps:get(<<"configured">>,M,false) of
                        true -> {ok,#{requested_ms => maps:get(<<"requested_ms">>,M), guarantee => <<"minimum_only">>}};
                        false -> {error,native_delay_control_unavailable}
                    end,
                    {keep_state,maps:remove(delay_caller,D),[{reply,From,Reply},{{timeout,minimum_delay},cancel}]};
                _ -> keep_state_and_data
            end;
        <<"playing">> ->
            maps:get(consumer,D) ! {parvi_audio_output,self(),
                #{state => <<"playing">>,cluster_synchronized => false}},
            keep_state_and_data;
        <<"paused">> ->
            maps:get(consumer,D) ! {parvi_audio_output,self(),
                #{state => <<"stopped">>,cluster_synchronized => false}},
            keep_state_and_data;
        <<"stats">> ->
            Report = parvi_webrtc_audio_timing:report(maps:get(source_timeline,D,undefined),M,
                maps:get(native_clock,D,undefined)),
            maps:get(consumer,D) ! {parvi_native_audio,self(),Report},
            {keep_state,D#{statistics => Report}};
        <<"clock">> ->
            {keep_state,clock_sample(M,D)};
        <<"error">> -> {stop,{native_audio,maps:get(<<"error">>,M)},D};
        _ -> keep_state_and_data
    end;
handle_event(info, {ex_webrtc, PC, {ice_candidate,C}}, _, #{pc := PC, peer := Peer}) ->
    signal(Peer,#{<<"event">> => <<"candidate">>, <<"candidate">> => ?ICE:to_json(C)}), keep_state_and_data;
handle_event(info, {ex_webrtc, PC, {connection_state_change,connected}}, _, #{pc := PC} = D) ->
    {next_state,active,D};
handle_event(info, {ex_webrtc, PC, {connection_state_change,failed}}, _, #{pc := PC} = D) -> {stop,connection_failed,D};
handle_event(info, stats, _, #{socket := Socket} = D) ->
    Next = request_clock(D),
    ok = send_native(Socket,#{op => <<"stats">>}), erlang:send_after(1000,self(),stats), {keep_state,Next};
handle_event(info, {tcp_closed,_}, _, D) -> {stop,native_audio_closed,D};
handle_event(info, {tcp_error,_,Reason}, _, D) -> {stop,{native_audio_error,Reason},D};
handle_event(info, {'DOWN',_,process,_,_}, _, D) -> {stop,normal,D};
handle_event(state_timeout,setup_timeout,_,D) -> {stop,setup_timeout,D};
handle_event({timeout,minimum_delay},command_timeout,_,#{delay_caller := {From,_}} = D) ->
    {keep_state,maps:remove(delay_caller,D),[{reply,From,{error,native_delay_control_timeout}}]};
handle_event(_,_,_,_) -> keep_state_and_data.

timeout() -> [{state_timeout,15000,setup_timeout}].
request_clock(#{socket := Socket} = D) ->
    Sent = erlang:monotonic_time(nanosecond),
    ok = send_native(Socket,#{op => <<"clock">>, sent_ns => Sent}), D#{clock_request_ns => Sent}.
clock_sample(#{<<"sent_ns">> := Sent, <<"host_ns">> := Host}, #{clock_request_ns := Sent} = D) ->
    Now = erlang:monotonic_time(nanosecond), RTT = Now-Sent,
    case RTT < maps:get(round_trip_ns,maps:get(native_clock,D,#{}),RTT+1) of
        true -> D#{native_clock => #{offset_ns => (Sent+Now) div 2-Host, round_trip_ns => RTT}};
        false -> D
    end;
clock_sample(_,D) -> D.
ice() -> application:get_env(parvi_transport,native_ice_servers,
    [#{urls => application:get_env(parvi,direct_stun_urls,[])}]).
signal(Peer,Message) -> gen_statem:cast(Peer,{signal,self(),Message}).
send_native(Socket,Message) -> gen_tcp:send(Socket,json:encode(Message)).
add_ice(PC,C) -> ?PC:add_ice_candidate(PC,?ICE:from_json(C)).
terminate(_,_,D) ->
    case maps:find(delay_caller,D) of {ok,{DelayFrom,_}} -> gen_statem:reply(DelayFrom,{error,closed}); _ -> ok end,
    case maps:find(caller,D) of {ok,From} -> gen_statem:reply(From,{error,closed}); _ -> ok end,
    case maps:find(socket,D) of {ok,Socket} -> gen_tcp:close(Socket); _ -> ok end,
    case maps:find(pc,D) of {ok,PC} -> try ?PC:close(PC) catch exit:_ -> ok end; _ -> ok end.
