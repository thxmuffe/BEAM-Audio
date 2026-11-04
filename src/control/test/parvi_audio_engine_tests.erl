-module(parvi_audio_engine_tests).
-include_lib("eunit/include/eunit.hrl").

%% Exercise both real adapters against a local native-service protocol endpoint.
%% No libwebrtc/GStreamer process, cluster, credentials or physical device is used.
native_protocol_test_() ->
    [{Name, fun() -> with_engine(Name, fun(Engine, Peer) ->
        Commands = [
            {play, #{op => <<"play">>}},
            {pause, #{op => <<"pause">>}},
            {stats, #{op => <<"stats">>}},
            {{clock,123}, #{op => <<"clock">>,sent_ns => 123}},
            {{signal,answer,#{sdp => <<"answer">>}}, #{op => <<"answer">>,sdp => <<"answer">>}},
            {{signal,candidate,#{candidate => #{value => <<"ice">>}}},
                #{op => <<"candidate">>,candidate => #{value => <<"ice">>}}},
            {{minimum_delay,200,1}, #{op => <<"minimum_delay">>,delay_ms => 200,request_id => 1}},
            {{minimum_delay,automatic,2}, #{op => <<"minimum_delay">>,delay_ms => null,request_id => 2}}
        ],
        [begin
            ?assertEqual(ok,parvi_audio_engine:command(Engine,Command)),
            ?assertEqual(wire(Expected),read(Peer))
         end || {Command,Expected} <- Commands],
        %% Active-once is rearmed by the adapter, so two successive events arrive.
        [begin
            Event = #{event => <<"stats">>,packetsReceived => N},
            ok = gen_tcp:send(Peer,json:encode(Event)),
            Message = receive M = {tcp,_,_} -> M after 1000 -> error(missing_event) end,
            ?assertEqual({ok,wire(Event)},parvi_audio_engine:event(Engine,Message))
         end || N <- [1,2]],
        ?assertEqual(ignore,parvi_audio_engine:event(Engine,unrelated_message)),
        ok = gen_tcp:close(Peer),
        Closed = receive M = {tcp_closed,_} -> M after 1000 -> error(missing_close) end,
        ?assertEqual({error,native_audio_closed},parvi_audio_engine:event(Engine,Closed))
    end) end} || Name <- ["libwebrtc","gstreamer"]].

selection_is_pinned_and_unsupported_controls_send_nothing_test() ->
    with_engine("gstreamer", fun(Engine, Peer) ->
        os:putenv("PARVI_AUDIO_ENGINE","libwebrtc"),
        ?assertMatch(#{id := <<"libwebrtc">>},parvi_audio_engine:info()),
        ?assertMatch(#{id := <<"gstreamer">>},parvi_audio_engine:info(Engine)),
        ?assertEqual({error,{unsupported_output_control,presentation_schedule_execution}},
            parvi_audio_engine:command(Engine,{presentation,#{revision => 1}})),
        ?assertEqual({error,{unsupported_output_control,rate_correction_control}},
            parvi_audio_engine:command(Engine,{rate_correction,#{correction_ppm => 5}})),
        ?assertEqual({error,timeout},gen_tcp:recv(Peer,0,20)),
        ?assertEqual(ok,parvi_audio_engine:command(Engine,play)),
        ?assertEqual(#{<<"op">> => <<"play">>},read(Peer))
    end).

scheduled_gstreamer_controls_are_explicit_test() ->
    with_engine("gstreamer", fun(Engine,Peer) ->
        os:putenv("PARVI_GSTREAMER_SCHEDULE","1"),
        ?assertMatch(#{presentation_schedule_execution := true,rate_correction_control := false},
            parvi_audio_engine:info(Engine)),
        Plan = #{generation => 3,ts_offset_ns => 4000,native_target_ns => 9000},
        ?assertEqual(ok,parvi_audio_engine:command(Engine,{presentation,Plan})),
        ?assertEqual(wire(#{op => <<"schedule">>,plan => Plan}),read(Peer)),
        Rate = #{correction_ppm => -25,max_absolute_ppm => 50},
        ?assertEqual({error,{unsupported_output_control,rate_correction_control}},
            parvi_audio_engine:command(Engine,{rate_correction,Rate})),
        ?assertEqual(ok,parvi_audio_engine:command(Engine,{invalidate_schedule,<<"clock_changed">>})),
        ?assertEqual(wire(#{op => <<"invalidate_schedule">>,reason => <<"clock_changed">>}),read(Peer)),
        ?assertEqual(ok,parvi_audio_engine:command(Engine,{diagnostic_sink_slaving,none})),
        ?assertEqual(wire(#{op => <<"diagnostic_sink_slaving">>,method => <<"none">>}),read(Peer)),
        ?assertEqual({error,adaptive_retiming_disabled},
            parvi_audio_engine:command(Engine,{diagnostic_sink_slaving,resample})),
        ?assertEqual(ok,parvi_audio_engine:command(Engine,{reject_packet,17,<<"late">>})),
        ?assertEqual(wire(#{op => <<"reject_packet">>,packet_id => 17,reason => <<"late">>}),read(Peer)),
        ?assertEqual({error,unsupported_output_control},
            parvi_audio_engine:command(Engine,{diagnostic_sink_slaving,unsupported})),
        ?assertEqual({error,timeout},gen_tcp:recv(Peer,0,20))
    end).

unsupported_selection_never_falls_back_test() ->
    with_env(fun() ->
        os:putenv("PARVI_AUDIO_ENGINE","not-an-installed-engine"),
        ?assertEqual(false,parvi_audio_engine:available()),
        ?assertEqual({error,unsupported_audio_engine},parvi_audio_engine:open(#{ice_servers => []}))
    end).

missing_native_output_returns_error_test() ->
    with_env(fun() ->
        os:unsetenv("PARVI_AUDIO_ENGINE"),
        os:unsetenv("PARVI_WEBRTC_AUDIO_PORT"),
        ?assertMatch(#{id := <<"libwebrtc">>},parvi_audio_engine:info()),
        ?assertEqual(false,parvi_audio_engine:available()),
        ?assertMatch({error,_},parvi_audio_engine:open(#{ice_servers => []}))
    end).

source_anchor_is_not_output_mapping_test() ->
    with_engine("libwebrtc", fun(Engine, _) ->
        Anchor = #{sample_position => 960,rtp_timestamp => 42,
            presentation => #{stream_id => <<"source">>,revision => 3,target_output_time_ns => 1234}},
        Report = parvi_audio_engine:output_status(Engine,Anchor,
            #{<<"outputRenderHostTimeNs">> => 1000,<<"outputRenderSampleTime">> => 480,
              <<"outputLatency">> => 0.02,<<"packetsLost">> => 2}),
        ?assertMatch(#{source_anchor := Anchor,source_output_mapping := unavailable,
            presentation_schedule_execution := false,rate_correction_control := false,
            render_host_time_ns := 1000,render_sample_position := 480,
            reported_output_latency_seconds := 0.02,calibrated_output_latency_ns := null,
            queue_depth_frames := null,underruns := null,lost_packets := 2,
            concealed_samples := null},Report)
    end).

wire(Map) -> json:decode(iolist_to_binary(json:encode(Map))).
read(Peer) -> {ok,Packet} = gen_tcp:recv(Peer,0,1000), json:decode(Packet).
with_engine(Name, Fun) ->
    with_env(fun() ->
        {ok,Listener} = gen_tcp:listen(0,[binary,{packet,4},{active,false},{ip,{127,0,0,1}}]),
        try
            {ok,{_,Port}} = inet:sockname(Listener),
            os:putenv("PARVI_WEBRTC_AUDIO_PORT",integer_to_list(Port)),
            os:putenv("PARVI_AUDIO_ENGINE",Name),
            {ok,Engine} = parvi_audio_engine:open(#{ice_servers => []}),
            try
                {ok,Peer} = gen_tcp:accept(Listener,1000),
                try
                    ?assertEqual(#{<<"op">> => <<"prepare">>,<<"ice_servers">> => []},read(Peer)),
                    Fun(Engine,Peer)
                after gen_tcp:close(Peer) end
            after parvi_audio_engine:close(Engine) end
        after gen_tcp:close(Listener) end
    end).
with_env(Fun) ->
    Saved = [{Key,os:getenv(Key)} || Key <- ["PARVI_AUDIO_ENGINE","PARVI_WEBRTC_AUDIO_PORT","PARVI_GSTREAMER_SCHEDULE"]],
    try Fun() after
        [case Value of false -> os:unsetenv(Key); _ -> os:putenv(Key,Value) end || {Key,Value} <- Saved]
    end.
