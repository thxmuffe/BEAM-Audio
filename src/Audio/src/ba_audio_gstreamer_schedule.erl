%% Shared Erlang scheduling arithmetic for GStreamer sink-clock execution.
%% Erlang chooses the target. Native code executes the returned sink offset.
-module(ba_audio_gstreamer_schedule).
-export([plan/3, source_position/3, rate_plan/2]).

%% Decode a source RTP position relative to the authorized session's anchor.
%% DecodedOffset is measured before any sample-rate conversion/time adjustment.
source_position(#{rtp_timestamp := Anchor, sample_position := Position}, RTP, DecodedOffset)
        when is_integer(RTP), is_integer(DecodedOffset) ->
    Delta = ((RTP-Anchor+16#80000000) band 16#ffffffff)-16#80000000,
    case abs(Delta) < 480000 of
        true -> {ok,Position+Delta+DecodedOffset};
        false -> {error,stale_source_anchor}
    end;
source_position(_,_,_) -> {error,source_anchor_unavailable}.

%% host_ns is the native monotonic observation paired with pipeline_clock_ns.
%% offset_ns maps native host coordinates to Erlang local monotonic coordinates.
%% running_time_ns has already been converted through the actual GstSegment.
plan(#{local_handoff_time_ns := LocalTarget, revision := Revision,
       stream_id := Stream, clock_timeline := Timeline},
     #{offset_ns := Offset},
     #{host_ns := Host, pipeline_clock_ns := Clock, base_time_ns := Base,
       running_time_ns := Running, pipeline_latency_ns := Latency,
       render_delay_ns := RenderDelay, observation_uncertainty_ns := Uncertainty})
        when is_integer(LocalTarget), is_integer(Offset), is_integer(Host),
             is_integer(Clock), is_integer(Base), is_integer(Running), Running >= 0,
             is_integer(Latency), Latency >= 0, is_integer(RenderDelay), RenderDelay >= 0,
             is_integer(Uncertainty), Uncertainty >= 0 ->
    NativeTarget = LocalTarget-Offset,
    case NativeTarget > Host+Uncertainty of
        true ->
            ClockTarget = Clock+(NativeTarget-Host),
            %% GstAudioBaseSink: base + running + ts-offset + latency - render-delay.
            TSOffset = ClockTarget-Base-Running-Latency+RenderDelay,
            {ok,#{ts_offset_ns => TSOffset, native_target_ns => NativeTarget,
                  pipeline_target_ns => ClockTarget, revision => Revision,
                  stream_id => Stream, clock_timeline => Timeline,
                  observation_uncertainty_ns => Uncertainty,
                  boundary => gstreamer_sink_clock_target}};
        false -> {error,target_not_in_future}
    end;
plan(_,_,_) -> {error,incomplete_pipeline_observation}.

%% Preserve clock phase at one internal coordinate while changing its rate.
%% This controls the proof's dedicated pipeline clock, not a global system clock.
rate_plan(#{correction_ppm := PPM,max_absolute_ppm := Limit},
          #{internal_ns := Internal,calibration_internal_ns := I0,
            calibration_external_ns := E0,rate_numerator := N,rate_denominator := D})
        when is_number(PPM),is_number(Limit),Limit >= 0,abs(PPM) =< Limit,
             PPM > -1000000,is_integer(Internal),is_integer(I0),is_integer(E0),
             is_integer(N),N > 0,is_integer(D),D > 0 ->
    External = E0+(Internal-I0)*N div D,
    Numerator = 1000000000+round(PPM*1000),
    case Numerator > 0 of
        true -> {ok,#{internal_ns => Internal,external_ns => External,
                      rate_numerator => Numerator,rate_denominator => 1000000000}};
        false -> {error,invalid_or_out_of_bounds_rate_correction}
    end;
rate_plan(_,_) -> {error,invalid_or_out_of_bounds_rate_correction}.
