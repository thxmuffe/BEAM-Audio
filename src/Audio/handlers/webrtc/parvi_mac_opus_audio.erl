%% Port-owned system capture + libopus; encoded audio only crosses BEAM.
-module(parvi_mac_opus_audio).
-behaviour(gen_server).
-export([start/0, stop/0, status/0, start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).
start() ->
    ok = parvi_audio_sup:ensure_started(),
    case supervisor:start_child(parvi_audio_sup, #{id => ?MODULE,
        start => {?MODULE, start_link, []}, restart => temporary}) of
        {ok, Pid} -> gen_server:call(Pid, start);
        {error, {already_started, Pid}} -> gen_server:call(Pid, start);
        Error -> Error
    end.
stop() -> case whereis(?MODULE) of undefined -> ok; Pid -> gen_server:stop(Pid) end.
status() -> case whereis(?MODULE) of undefined -> #{state => stopped}; Pid -> gen_server:call(Pid, status) end.
start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).
init([]) -> {ok, #{state => stopped, frames => 0, blocks => 0, dropped_callbacks => 0, capture_timing => #{},
    presentation_state => #{stream_id => binary:encode_hex(crypto:strong_rand_bytes(16))},
    presentation_delay_ns => application:get_env(parvi,audio_presentation_delay_ms,250)*1000000,
    skipped_frames => 0, send_errors => 0, available => os:getenv("PARVI_MAC_OPUS_HELPER") =/= false}}.
handle_call(start, _, #{state := stopped} = S) ->
    case os:getenv("PARVI_MAC_OPUS_HELPER") of
        false -> {reply, {error, <<"Rebuild the Mac app with the Opus comparison helper.">>}, S};
        Helper ->
            Port = open_port({spawn_executable, Helper}, [binary, {packet,4}, exit_status, use_stdio]),
            {reply, ok, S#{port => Port, state := starting}}
    end;
handle_call(start, _, S) -> {reply, ok, S};
handle_call(status, _, S) -> {reply, maps:without([port, source, source_monitor], S), S};
handle_call(_, _, S) -> {reply, {error, unsupported_request}, S}.
handle_cast(_, S) -> {noreply, S}.
handle_info({Port, {data, <<1, Metadata/binary>>}}, #{port := Port} = S) ->
    Format = parvi_core_audio:format(Metadata),
    Descriptor = #{encoding => opus, sample_format => opus, sample_rate => 48000,
        channel_count => 2, clock => <<"native_webrtc_audio_comparison">>,
        stream_handler => webrtc_audio_opus},
    {ok, Source} = parvi_audio:publish(#{name => <<"Mac output - Opus / NetEq comparison">>,
        profiles => #{channel => Descriptor}}, self()),
    {noreply, read(S#{state := running, source => Source, source_monitor => monitor(process, Source),
        capture_format => Format, format => #{rate => 48000, channels => 2}, handler => <<"webrtc_audio_opus">>})};
handle_info({Port, {data, <<8, Host:64/little, Position:64/little-float,
                          Dropped:64/little, Flags:32/little, _Buffers:32/little, Frames:32/little, OutputPosition:64/little>>}},
            #{port := Port, capture_format := Format, capture_timing := Timing} = S) ->
    Observation = #{valid => Flags band 3 =:= 3, position => Position, frames => Frames,
        host_ns => parvi_core_audio:host_ns(Host,Format), dropped => Dropped,
        output_position => OutputPosition},
    {noreply,S#{capture_timing := parvi_webrtc_audio_timing:observe(Observation,Timing),
               dropped_callbacks := Dropped}};
handle_info({Port, {data, <<6, Position:64/little, Lookahead:32/little,
                          Leading:32/little, Trailing:32/little, Packet/binary>>}},
            #{port := Port, source := Source, capture_timing := Timing} = S) ->
    CaptureHeader = parvi_webrtc_audio_timing:capture(Position,
        #{encoder_lookahead_frames => Lookahead, converter_leading_input_frames => Leading,
          converter_trailing_input_frames => Trailing,
          capture_clock_round_trip_ns => maps:get(best_round_trip,S,null)},Timing),
    ClockTimeline = maps:get(timeline,parvi_clock:status(),undefined),
    {Header,Presentation} = parvi_audio_presentation:stamp(CaptureHeader,
        maps:get(presentation_delay_ns,S),ClockTimeline,maps:get(presentation_state,S)),
    ok = gen_server:call(Source, {push_encoded, Header, Packet}),
    {noreply, S#{frames := maps:get(frames,S)+960, blocks := maps:get(blocks,S)+1,
                timeline => Header, presentation_state := Presentation}};
handle_info({Port, {data, <<4>>}}, #{port := Port} = S) ->
    erlang:send_after(10,self(),read), {noreply,S};
handle_info(read, S) -> {noreply,read(S)};
handle_info({Port, {data, <<5, Host:64/little>>}},
            #{port := Port, request_sent := Sent, capture_format := Format} = S) ->
    Now = erlang:monotonic_time(nanosecond), RTT = Now-Sent,
    Next = case RTT < maps:get(best_round_trip,S,RTT+1) of
        true ->
            Offset = (Sent+Now) div 2 - parvi_core_audio:host_ns(Host,Format),
            S#{capture_timing := (maps:get(capture_timing,S))#{clock_offset_ns => Offset}, best_round_trip => RTT};
        false -> S
    end,
    {noreply,Next};
handle_info({Port, {data, <<3, _Code:32/little-signed, Text/binary>>}}, #{port := Port} = S) ->
    parvi_chat:system(error,audio_error,<<"[Audio] Opus capture: ",Text/binary>>,#{}),
    {stop, {capture_failed, Text}, S};
handle_info({Port, {exit_status, Code}}, #{port := Port} = S) -> {stop, {capture_exit, Code}, S};
handle_info({'DOWN', Ref, process, _, _}, #{source_monitor := Ref} = S) -> {stop, normal, S};
handle_info(_, S) -> {noreply,S}.
read(#{port := Port} = S) ->
    Sent = erlang:monotonic_time(nanosecond), true = port_command(Port, <<$r>>), S#{request_sent => Sent}.
terminate(_, S) ->
    case maps:find(port,S) of {ok,P} -> try port_close(P) catch error:badarg -> ok end; _ -> ok end,
    case maps:find(source,S) of {ok,Source} -> try parvi_audio:unpublish(Source) catch exit:_ -> ok end; _ -> ok end.
