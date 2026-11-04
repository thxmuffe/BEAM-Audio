%% One supervised endpoint per side. SDP/ICE use the authorized BEAM peer;
%% media uses DTLS-SRTP; a pinned local engine owns decode/device execution.
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
init({provider, Source, Peer, #{selector := all,packet_target_clock := global_playback_48k_v1} = Request, Descriptor}) ->
    monitor(process, Source), monitor(process, Peer),
    {ok, PC} = ?PC:start_link([{ice_servers, ice()}, {video_codecs, []}]),
    monitor(process, PC),
    Track = 'Elixir.ExWebRTC.MediaStreamTrack':new(audio),
    {ok, _} = ?PC:add_track(PC, Track),
    {ok, negotiating, #{role => provider, source => Source, peer => Peer, descriptor => Descriptor,
        pc => PC, track => maps:get(id,Track), sequence => rand:uniform(65536)-1,
        timing_observations => maps:get(timing_observations,Request,false), pending_ice => []}, timeout()};
init(_) -> {stop, unsupported_audio_comparison_request}.

handle_event({call, From}, {open, Source, Request}, idle, D) ->
    monitor(process, Source), Id = gen_server:send_request(Source, {subscribe,Request#{timing_observations => true,packet_target_clock => global_playback_48k_v1}}),
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
    case open_scheduled_engine() of
        {ok, Engine} ->
            erlang:send_after(1000,self(),stats),
            Next = request_clock(D#{engine => Engine, caller => From}),
            {next_state,negotiating,Next,timeout()};
        {error, Reason} ->
            {stop_and_reply,normal,[{reply,From,{error,Reason}}],D}
    end;
handle_event({call, From}, {playback, Action}, active, #{engine := Engine} = D) ->
    Command = case Action of start -> play; stop -> pause end,
    Reply = parvi_audio_engine:command(Engine,Command),
    {keep_state,D,[{reply,From,Reply}]};
handle_event({call, From}, status, State, D) ->
    {keep_state_and_data,[{reply,From,#{state => State, backend => parvi_audio_stream_handler_webrtc:info(),
        engine => engine_info(D),unscheduled_packets => maps:get(unscheduled_packets,D,0),
        statistics => maps:get(statistics,D,#{})}}]};
%% Compatibility for existing local callers; the receiver now uses output_control.
handle_event({call, From}, {minimum_playout_delay, Delay}, State, D) ->
    handle_event({call,From},{output_control,{minimum_delay,Delay}},State,D);
handle_event({call, From}, {output_control,{minimum_delay,Delay}}, active, #{engine := Engine} = D)
        when not is_map_key(delay_caller,D),
             (Delay =:= automatic orelse (is_integer(Delay) andalso Delay >= 0 andalso Delay =< 10000)) ->
    Id = erlang:unique_integer([positive,monotonic]),
    ok = parvi_audio_engine:command(Engine,{minimum_delay,Delay,Id}),
    {keep_state,D#{delay_caller => {From,Id}},[{{timeout,minimum_delay},2000,command_timeout}]};
handle_event({call, From}, {output_control,{Kind, _} = Command}, active, #{engine := Engine} = D)
        when Kind =:= presentation; Kind =:= rate_correction ->
    {keep_state,D,[{reply,From,parvi_audio_engine:command(Engine,Command)}]};
handle_event({call, From}, {output_control,{diagnostic_sink_slaving,resample}}, active, _) ->
    {keep_state_and_data,[{reply,From,{error,adaptive_retiming_disabled}}]};
%% Inspect the readback before treating a queued request as applied.
handle_event({call, From}, {output_control,{diagnostic_sink_slaving,Method} = Command}, active,
             #{engine := Engine} = D) when Method =:= none ->
    Reply = case maps:is_key(<<"sinkClockSlaving">>,maps:get(statistics,D,#{})) of
        true ->
            ok = parvi_audio_engine:command(Engine,Command),
            {ok,#{status => queued,requested => Method}};
        false -> {error,diagnostic_sink_slaving_unavailable}
    end,
    {keep_state,D,[{reply,From,Reply}]};
handle_event({call, From}, _, _, _) -> {keep_state_and_data,[{reply,From,{error,invalid_state}}]};
handle_event(cast, {encoded, Source, #{sample_position := Position} = Timing, Packet}, active,
             #{role := provider, source := Source, pc := PC, track := Track,
               sequence := Seq} = D) ->
    case parvi_audio_rtp_time:packet(Packet,Timing,Seq,Seq =:= 0) of
        {error,packet_playback_target_unavailable} ->
            {keep_state,D#{unscheduled_packets => maps:get(unscheduled_packets,D,0)+1}};
        {ok,RTP} ->
            Time = maps:get(timestamp,RTP),
            ok = ?PC:send_rtp(PC,Track,RTP),
    %% Auxiliary capture diagnostics only. Playback targets are IN EVERY RTP header.
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
    {keep_state,Next#{sequence := (Seq+1) band 16#ffff}}
    end;
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
             #{role := receiver, peer := Peer, engine := Engine} = D) ->
    Kind = case Event of <<"answer">> -> answer; <<"candidate">> -> candidate end,
    ok = parvi_audio_engine:command(Engine,{signal,Kind,maps:remove(<<"event">>,Message)}), {keep_state,D};
handle_event(info, {ex_webrtc, PC, {ice_candidate,C}}, _, #{pc := PC, peer := Peer}) ->
    signal(Peer,#{<<"event">> => <<"candidate">>, <<"candidate">> => ?ICE:to_json(C)}), keep_state_and_data;
handle_event(info, {ex_webrtc, PC, {connection_state_change,connected}}, _, #{pc := PC} = D) ->
    {next_state,active,D};
handle_event(info, {ex_webrtc, PC, {connection_state_change,failed}}, _, #{pc := PC} = D) -> {stop,connection_failed,D};
handle_event(info, stats, _, #{engine := Engine} = D) ->
    Next = request_clock(D),
    ok = parvi_audio_engine:command(Engine,stats), erlang:send_after(1000,self(),stats), {keep_state,Next};
handle_event(info, {'DOWN',_,process,_,_}, _, D) -> {stop,normal,D};
handle_event(state_timeout,setup_timeout,_,D) -> {stop,setup_timeout,D};
handle_event({timeout,minimum_delay},command_timeout,_,#{delay_caller := {From,_}} = D) ->
    {keep_state,maps:remove(delay_caller,D),[{reply,From,{error,native_delay_control_timeout}}]};
handle_event(info, Message, State, #{role := receiver,engine := Engine} = D) ->
    case parvi_audio_engine:event(Engine,Message) of
        {ok, Event} -> engine_event(Event,State,D);
        {error, Reason} -> {stop,Reason,D};
        ignore -> keep_state_and_data
    end;
handle_event(_,_,_,_) -> keep_state_and_data.

open_scheduled_engine() ->
    case parvi_audio_engine:info() of
        #{presentation_schedule_execution := true} -> parvi_audio_engine:open(#{ice_servers => ice()});
        _ -> {error,<<"This audio engine cannot execute per-packet playback targets.">>}
    end.

engine_info(#{engine := Engine}) -> parvi_audio_engine:info(Engine);
engine_info(_) -> null.

engine_event(M,State,#{peer := Peer,engine := Engine} = D) ->
    case maps:get(<<"event">>,M) of
        <<"offer">> -> signal(Peer,M), keep_state_and_data;
        <<"candidate">> -> signal(Peer,M), keep_state_and_data;
        <<"connected">> when State =:= negotiating ->
            %% This controls transport jitter buffering only, never the packet target.
            ok = parvi_audio_engine:command(Engine,{minimum_delay,automatic,0}),
            {next_state,active,maps:remove(caller,D),[{reply,maps:get(caller,D),ok}]};
        <<"minimum_delay">> ->
            case {maps:get(delay_caller,D,undefined),maps:get(<<"request_id">>,M,undefined)} of
                {{From,Id},Id} ->
                    Reply = case maps:get(<<"configured">>,M,false) of
                        true ->
                            Info = parvi_audio_engine:info(Engine),
                            {ok,#{requested_ms => maps:get(<<"requested_ms">>,M),
                                  guarantee => atom_to_binary(maps:get(minimum_delay_control,Info))}};
                        false -> {error,native_delay_control_unavailable}
                    end,
                    {keep_state,maps:remove(delay_caller,D),[{reply,From,Reply},{{timeout,minimum_delay},cancel}]};
                _ -> keep_state_and_data
            end;
        <<"pipeline_observation">> ->
            {keep_state,plan_gstreamer(M,D)};
        <<"schedule">> ->
            {keep_state,D#{schedule_reply => M}};
        <<"rate">> -> keep_state_and_data;
        <<"playing">> ->
            maps:get(consumer,D) ! {parvi_audio_output,self(),
                #{state => <<"playing">>,cluster_synchronized => false}},
            keep_state_and_data;
        <<"paused">> ->
            maps:get(consumer,D) ! {parvi_audio_output,self(),
                #{state => <<"stopped">>,cluster_synchronized => false}},
            keep_state_and_data;
        <<"stats">> ->
            Measured = maps:merge(M,maps:get(schedule_diagnostics,D,#{})),
            Timing = parvi_webrtc_audio_timing:report(maps:get(source_timeline,D,undefined),Measured,
                maps:get(native_clock,D,undefined)),
            Report = Timing#{<<"output_engine">> => parvi_audio_engine:info(Engine),
                <<"output_status">> => parvi_audio_engine:output_status(Engine,
                    maps:get(source_timeline,D,undefined),Timing)},
            maps:get(consumer,D) ! {parvi_native_audio,self(),Report},
            {keep_state,D#{statistics => Report}};
        <<"clock">> ->
            {keep_state,clock_sample(M,D)};
        <<"error">> -> {stop,{native_audio,maps:get(<<"error">>,M)},D};
        _ -> keep_state_and_data
    end.

timeout() -> [{state_timeout,15000,setup_timeout}].
request_clock(#{engine := Engine} = D) ->
    Sent = erlang:monotonic_time(nanosecond),
    ok = parvi_audio_engine:command(Engine,{clock,Sent}), D#{clock_request_ns => Sent}.
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
add_ice(PC,C) -> ?PC:add_ice_candidate(PC,?ICE:from_json(C)).
terminate(_,_,D) ->
    case maps:find(delay_caller,D) of {ok,{DelayFrom,_}} -> gen_statem:reply(DelayFrom,{error,closed}); _ -> ok end,
    case maps:find(caller,D) of {ok,From} -> gen_statem:reply(From,{error,closed}); _ -> ok end,
    case maps:find(engine,D) of {ok,Engine} -> parvi_audio_engine:close(Engine); _ -> ok end,
    case maps:find(pc,D) of {ok,PC} -> try ?PC:close(PC) catch exit:_ -> ok end; _ -> ok end.

%% All schedule/servo policy stays on the session process, outside device callbacks.
plan_gstreamer(M,D0) ->
    D = schedule_diagnostic(<<"controllerObservationCount">>,#{},D0),
    #{engine := Engine} = D,
    Keys = [rtp_timestamp,packet_id,host_ns,pipeline_clock_ns,base_time_ns,running_time_ns,
            pipeline_latency_ns,render_delay_ns,observation_uncertainty_ns,generation],
    Observation = maps:from_list([{K,maps:get(atom_to_binary(K),M)} || K <- Keys]),
    Source = maps:get(descriptor,D),
    Reference = parvi_clock:status(),
    case {parvi_audio_gstreamer_control:target(Source,Observation,Reference),maps:find(native_clock,D)} of
        {{ok,Target},{ok,Bridge}} ->
            case parvi_clock:to_monotonic(maps:get(target_output_time_ns,Target)) of
                {ok,Local} ->
                    Pipeline = Observation#{observation_uncertainty_ns :=
                        maps:get(observation_uncertainty_ns,Observation)+maps:get(round_trip_ns,Bridge) div 2},
                    case parvi_audio_gstreamer_schedule:plan(Target#{local_handoff_time_ns => Local},Bridge,Pipeline) of
                        {ok,Plan0} ->
                            Plan = maps:merge(Target,Plan0#{generation => maps:get(generation,Observation),
                                rtp_timestamp => maps:get(rtp_timestamp,Observation),packet_id => maps:get(packet_id,Observation),
                                local_handoff_time_ns => Local,calibrated_output_latency_ns => null}),
                            ok = parvi_audio_engine:command(Engine,{presentation,Plan}),
                            schedule_diagnostic(<<"controllerPacketPlanRequests">>,#{},D);
                        {error,Reason} -> reject_gstreamer_packet(Reason,M,D)
                    end;
                {error,_} -> reject_gstreamer_packet(receiver_clock_unavailable,M,D)
            end;
        _ -> reject_gstreamer_packet(packet_target_clock_unavailable,M,D)
    end.
reject_gstreamer_packet(Reason,M,#{engine := Engine} = D) ->
    ok = parvi_audio_engine:command(Engine,{reject_packet,maps:get(<<"packet_id">>,M),atom_to_binary(Reason)}),
    schedule_diagnostic(<<"controllerRejectedPacketTargets">>,
        #{<<"controllerLastRejection">> => atom_to_binary(Reason)},D).

schedule_diagnostic(Counter,Fields,D) ->
    Previous = maps:get(schedule_diagnostics,D,#{}),
    D#{schedule_diagnostics => maps:merge(Previous,Fields#{
        Counter => maps:get(Counter,Previous,0)+1})}.
