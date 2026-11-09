%% Receiver media execution. The existing session owns the selected engine/handle.
-module(ba_audio_engine).
-export([open/1, available/0, info/0, info/1, command/2, event/2, close/1, output_status/3]).
-export_type([engine/0, command/0, presentation/0, rate_correction/0]).

-type engine() :: #{module := module(), handle := term()}.
%% Shared target + local handoff. A native sink-clock trial leaves path delay null.
-type presentation() :: #{stream_id := binary(), revision := non_neg_integer(),
    clock_timeline := binary(), sample_position := non_neg_integer(),
    sample_rate := pos_integer(), target_output_time_ns := integer(),
    local_handoff_time_ns := integer(), calibrated_output_latency_ns := non_neg_integer() | null}.
-type rate_correction() :: #{stream_id := binary(), revision := non_neg_integer(),
    clock_timeline := binary(), correction_ppm := number(), max_absolute_ppm := number()}.
-type command() :: play | pause | stats | {clock, integer()} |
    {signal, answer | candidate, map()} |
    {minimum_delay, automatic | non_neg_integer(), integer()} |
    {presentation, presentation()} | {rate_correction, rate_correction()} |
    {diagnostic_sink_slaving, none | resample}.

-callback info() -> map().
-callback available() -> boolean().
-callback open(map()) -> {ok, term()} | {error, term()}.
-callback command(term(), command()) -> ok | {error, term()}.
-callback event(term(), term()) -> ignore | {ok, map()} | {error, term()}.
-callback close(term()) -> ok.

%% Only local platform configuration selects modules. Remote descriptors never do.
%% The default keeps existing iPhone hosts compatible with this Erlang update.
selected() ->
    case os:getenv("BA_AUDIO_ENGINE") of
        false -> {ok, ba_audio_engine_libwebrtc};
        "libwebrtc" -> {ok, ba_audio_engine_libwebrtc};
        "gstreamer" -> {ok, ba_audio_engine_gstreamer};
        _ -> {error, unsupported_audio_engine}
    end.

open(Options) ->
    case selected() of
        {ok, Module} ->
            case Module:open(Options) of
                {ok, Handle} -> {ok, #{module => Module, handle => Handle}};
                Error -> Error
            end;
        Error -> Error
    end.
available() ->
    case selected() of {ok, Module} -> Module:available(); _ -> false end.
info() ->
    case selected() of
        {ok, Module} -> Module:info();
        {error, Reason} -> #{id => <<"unavailable">>, error => Reason}
    end.
info(#{module := Module}) -> Module:info().

%% These are explicit operations, not aliases for a minimum buffer setting.
%% Only a locally enabled executor accepts them; other platforms stay unchanged.
command(Engine, {presentation, _} = Command) ->
    supported(Engine, presentation_schedule_execution, Command);
command(Engine, {rate_correction, _} = Command) ->
    supported(Engine, rate_correction_control, Command);
command(#{module := Module, handle := Handle}, Command) -> Module:command(Handle, Command).
supported(#{module := Module, handle := Handle}, Capability, Command) ->
    case maps:get(Capability, Module:info(), false) of
        true -> Module:command(Handle, Command);
        false -> {error, {unsupported_output_control, Capability}}
    end.
event(#{module := Module, handle := Handle}, Message) -> Module:event(Handle, Message).
close(#{module := Module, handle := Handle}) -> Module:close(Handle).

%% Common output report. A source anchor is never an output sample association.
%% Missing measurements stay null; route reports are not calibrated path delay.
output_status(Engine, Timeline, Stats) ->
    #{engine => info(Engine),
      source_anchor => case is_map(Timeline) of true -> Timeline; false -> null end,
      source_output_mapping => case maps:get(<<"output_schedule_enforced">>,Stats,false) of
          true -> packet_global_target; false -> unavailable end,
      presentation_schedule_execution => maps:get(<<"output_schedule_enforced">>,Stats,false),
      rate_correction_control => maps:get(rate_correction_control,info(Engine),false),
      output_timing_status => maps:get(<<"output_timing_status">>, Stats, <<"unavailable">>),
      render_host_time_ns => maps:get(<<"outputRenderHostTimeNs">>, Stats, null),
      render_sample_position => maps:get(<<"outputRenderSampleTime">>, Stats, null),
      render_sample_rate => maps:get(<<"outputRenderSampleRate">>, Stats, null),
      reported_output_latency_seconds => maps:get(<<"outputLatency">>, Stats, null),
      calibrated_output_latency_ns => null, queue_depth_frames => null, underruns => null,
      dropped_output_buffers => maps:get(<<"outputDroppedBuffers">>, Stats, null),
      lost_packets => maps:get(<<"packetsLost">>, Stats, null),
      concealed_samples => maps:get(<<"concealedSamples">>, Stats, null)}.
