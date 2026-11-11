%% Timing observations only. No audio buffering, clock selection or correction.
-module(ba_webrtc_audio_timing).
-export([observe/2, capture/3, report/3]).

%% Input positions detect loss/reset; output positions belong to the encoder's
%% separate 48 kHz stream. A gap changes their relationship without resetting RTP.
observe(#{valid := true, position := Position, frames := Frames,
          host_ns := Host, dropped := Dropped, output_position := Output}, S) ->
    Stable = abs(Position - maps:get(expected_position,S,Position)) < 0.5 andalso
        Dropped =:= maps:get(dropped,S,Dropped),
    Next = case {Stable,maps:get(needs_anchor,S,false),maps:is_key(anchor_position,S)} of
        {true,false,true} -> S#{continuous => true};
        _ ->
            S#{anchor_host_ns => Host, anchor_position => Output,
               segment => maps:get(segment,S,0)+1,
               segment_start_position => ((Output+959) div 960)*960,
               continuous => Stable andalso not maps:get(needs_anchor,S,false)}
    end,
    Residual = Host - maps:get(anchor_host_ns,Next) -
        (Output-maps:get(anchor_position,Next))*1000000000 div 48000,
    Next#{expected_position => Position+Frames, dropped => Dropped,
          needs_anchor => false, capture_host_residual_ns => Residual};
observe(_, S) -> S#{continuous => false,needs_anchor => true}.

capture(Position, Codec, S) ->
    Start = maps:get(segment_start_position,S,0),
    Continuous = maps:get(continuous,S,false) andalso Position >= Start,
    Capture = case S of
        #{anchor_host_ns := Anchor, anchor_position := AnchorPosition, clock_offset_ns := Offset}
                when Continuous ->
            Mono = Anchor + Offset + (Position-AnchorPosition)*1000000000 div 48000,
            case ba_buffee_clock:from_monotonic(Mono) of
                {ok, Time} -> Time;
                _ -> null
            end;
        _ -> null
    end,
    Codec#{sample_position => Position, sample_rate => 48000,
           estimated_capture_time_ns => Capture, clock => ba_buffee_clock:id(),
           continuous => Continuous, capture_segment => maps:get(segment,S,0),
           segment_start_position => Start,
           capture_host_residual_ns => maps:get(capture_host_residual_ns,S,0),
           mapping => <<"nominal_uncompensated">>}.

report(Timeline, Stats, Clock) ->
    scheduled_report(Timeline,presentation_report(Timeline,output_report(track_report(Timeline,Stats,Clock),Clock))).

%% Report intent separately from observed delivery/output. The Opus handler does
%% not execute this schedule yet; never label a target as a measured speaker time.
presentation_report(Timeline,Stats) ->
    Base = (maps:without([<<"target_output_time_ns">>,<<"presentation_schedule">>],Stats))#{
        <<"output_schedule_enforced">> => false},
    case {Timeline,Stats} of
        {#{presentation := Schedule,rtp_timestamp := AnchorRTP,sample_position := Position},
         #{<<"capture_timing_status">> := <<"available">>, <<"sourceRtpTimestamp">> := RTP}} ->
            Delta = ((RTP-AnchorRTP+16#80000000) band 16#ffffffff)-16#80000000,
            Base#{<<"presentation_status">> => <<"target_known_output_control_unavailable">>,
                  <<"presentation_schedule">> => Schedule,
                  <<"target_output_time_ns">> => ba_audio_presentation:target(Schedule,Position+Delta)};
        _ -> Base#{<<"presentation_status">> => <<"waiting_for_valid_source_schedule">>}
    end.

%% RemoteIO timestamps describe the output callback, not an RTP sample or a
%% measured speaker emission. Route latency stays separate, without double counting.
output_report(Stats,Clock) ->
    Base = maps:without([<<"output_render_time_ns">>,<<"output_render_age_ms">>],Stats),
    case {Stats,Clock} of
        {#{<<"outputRenderHostTimeNs">> := Host,
           <<"outputRenderObservedHostTimeNs">> := Observed,
           <<"outputTimingObservedHostTimeNs">> := Now,
           <<"outputRenderStatus">> := 0}, #{offset_ns := Offset}}
                when is_integer(Host), is_integer(Observed), is_integer(Now),
                     Now >= Observed, Now-Observed < 2000000000 ->
            case ba_buffee_clock:from_monotonic(Host+Offset) of
                {ok,Time} -> Base#{<<"output_timing_status">> => <<"callback_mapped_uncompensated">>,
                                  <<"output_render_time_ns">> => Time,
                                  <<"output_render_age_ms">> => (Now-Observed)/1000000};
                _ -> Base#{<<"output_timing_status">> => <<"receiver_clock_unavailable">>}
            end;
        _ -> Base#{<<"output_timing_status">> => <<"output_callback_unavailable_or_stale">>}
    end.

track_report(undefined, Stats, _) -> unavailable(<<"waiting_for_source_timeline">>,Stats);
track_report(Timeline, Stats, Clock) ->
    %% A retained estimate must never survive a missing/new segment observation.
    Base = (maps:without([<<"estimated_capture_to_track_ms">>,<<"track_delivery_time_ns">>],Stats))#{
        <<"source_timeline">> => Timeline},
    case {Timeline, Stats, Clock} of
        {#{rtp_timestamp := AnchorRTP, estimated_capture_time_ns := Capture},
         #{<<"sourceRtpTimestamp">> := RTP, <<"sourceTimestampUs">> := TrackUS,
           <<"sourceObservedHostTimeNs">> := Observed},
         #{offset_ns := Offset, round_trip_ns := RTT}}
                when is_integer(Capture), is_integer(RTP), is_number(TrackUS) ->
            TrackHost = round(TrackUS * 1000),
            Delta = ((RTP - AnchorRTP + 16#80000000) band 16#ffffffff) - 16#80000000,
            %% Sources can be retained for ten seconds. Do not extrapolate a
            %% stale source/anchor or assume an unrelated timestamp epoch.
            case Observed >= TrackHost andalso Observed - TrackHost < 10000000000
                    andalso abs(Delta) < 480000 of
                true ->
                    AfterBoundary = maps:get(sample_position,Timeline,0)+Delta >=
                        maps:get(segment_start_position,Timeline,0),
                    case {AfterBoundary,ba_buffee_clock:from_monotonic(TrackHost + Offset)} of
                        {true,{ok, Delivery}} ->
                            SampleCapture = Capture + Delta * 1000000000 div 48000,
                            Base#{<<"capture_timing_status">> => <<"available">>,
                                  <<"estimated_capture_to_track_ms">> => (Delivery-SampleCapture)/1000000,
                                  <<"track_delivery_time_ns">> => Delivery,
                                  <<"native_clock_round_trip_ns">> => RTT};
                        {false,_} -> unavailable(<<"waiting_for_current_capture_segment">>,Base);
                        _ -> unavailable(<<"receiver_clock_unavailable">>,Base)
                    end;
                false -> unavailable(<<"stale_or_unmatched_track_timestamp">>,Base)
            end;
        {#{continuous := false},_,_} -> unavailable(<<"capture_interrupted">>,Base);
        {#{estimated_capture_time_ns := null},_,_} -> unavailable(<<"source_clock_unavailable">>,Base);
        {_,_,undefined} -> unavailable(<<"waiting_for_native_clock">>,Base);
        _ -> unavailable(<<"waiting_for_track_timestamp">>,Base)
    end.

unavailable(Reason,Stats) ->
    (maps:without([<<"estimated_capture_to_track_ms">>,<<"track_delivery_time_ns">>,
                   <<"native_clock_round_trip_ns">>],Stats))#{<<"capture_timing_status">> => Reason}.

%% Only a plan derived from the current packet's global RTP target is accepted.
scheduled_report(_,#{<<"sinkScheduleEnforced">> := true,<<"packetTargetExecution">> := true,
    <<"appliedSchedule">> := #{<<"basis">> := <<"packet_global_playback_target">>,
        <<"rtp_timestamp">> := RTP,<<"target_output_time_ns">> := Target}} = Stats)
        when is_integer(RTP),is_integer(Target) ->
    Stats#{<<"output_schedule_enforced">> => true,
        <<"presentation_status">> => <<"per_packet_global_target_execution">>,
        <<"output_timing_status">> => <<"packet_target_to_local_sink_clock">>};
scheduled_report(_,Stats) -> Stats.
