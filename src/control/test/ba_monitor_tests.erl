-module(ba_monitor_tests).
-include_lib("eunit/include/eunit.hrl").

render_utc_clock_source_and_age_test() ->
    View=#{<<"session">> => #{},<<"state">> => <<"authorized">>,<<"devices">> => []},
    Clock=#{<<"state">> => <<"synchronized">>,<<"utc_time_ns">> => 1794941608123456789,<<"age_ns">> => 12000000000,
        <<"source">> => <<"ntp">>,<<"reference">> => <<"ntp.metas.ch">>,<<"last_error">> => null},
    Render=fun(C) -> iolist_to_binary(ba_cli_monitor:render(View#{<<"clock">> => C})) end,
    ?assertNotEqual(nomatch,binary:match(Render(Clock),<<"Clock: 2026-11-17T18:53:28.123Z UTC | ntp.metas.ch | read 12 s ago">>)),
    ?assertNotEqual(nomatch,binary:match(Render(Clock#{<<"source">> := <<"system">>}),<<"| system clock |">>)),
    ?assertNotEqual(nomatch,binary:match(Render(#{}),<<"Clock: N/A">>)).

render_shared_response_time_and_readiness_test() ->
    View=#{<<"session">> => #{},<<"state">> => <<"authorized">>,<<"devices">> => []},
    Render=fun(P) -> iolist_to_binary(ba_cli_monitor:render(View#{<<"clock">> => #{<<"offset_policy">> => P}})) end,
    ?assertNotEqual(nomatch,binary:match(Render(#{<<"offset_ms">> => 150,<<"ready">> => true}),<<"Response time: 150 ms\n">>)),
    ?assertNotEqual(nomatch,binary:match(Render(#{<<"offset_ms">> => 800,<<"ready">> => false}),<<"Response time: 800 ms (not ready)">>)),
    ?assertNotEqual(nomatch,binary:match(Render(#{}),<<"Response time: N/A">>)),
    ?assertNotEqual(nomatch,binary:match(Render(#{<<"offset_ms">> => 150,<<"ready">> => true,<<"measured_ms">> => 92,<<"measured">> => [80,104]}),
        <<"Response time: 150 ms  measured: 92 ms average of 2 Devices">>)).

render_missing_levels_is_not_silence_test() ->
    Id=binary:copy(<<"A">>,64),Entry=#{<<"state">> => <<"running">>,<<"consent">> => true,<<"available">> => true},
    View=#{<<"session">> => #{<<"name">> => <<"Test">>,<<"session">> => binary:copy(<<"B">>,32)},<<"state">> => <<"authorized">>,
        <<"devices">> => [#{<<"id">> => Id,<<"state">> => <<"ok">>,<<"capabilities">> => #{<<"audio">> => #{<<"broadcast">> => Entry}}}]},
    Text=iolist_to_binary(ba_cli_monitor:render(View)),
    %% Missing levels are left out, never shown as silence.
    ?assertEqual(nomatch,binary:match(Text,<<"-96.0">>)),
    ?assertNotEqual(nomatch,binary:match(Text,<<"running">>)).


gossiped_levels_keep_the_last_observation_for_each_signal_test() ->
    Speaker=#{<<"peak_db">> => -9.0,<<"rms_db">> => -14.0,<<"meter_age_ms">> => 10},
    Mic=Speaker#{<<"peak_db">> := -3.0},
    Report=fun(Time,Levels,S) -> ba_audio_observer:handle_cast({reported_levels,<<"peer">>,
        #{<<"sampled_at_ms">> => Time,<<"levels">> => Levels}},S) end,
    {noreply,S1}=Report(20,#{<<"speaker">> => Speaker},#{}),
    {noreply,S2}=Report(21,#{<<"microphone">> => Mic},S1),
    ?assertEqual({noreply,S2},Report(19,#{<<"speaker">> => Mic},S2)),
    {reply,Levels,_}=ba_audio_observer:handle_call(session_levels,undefined,S2),
    ?assertMatch(#{<<"peer">> := #{<<"speaker">> := #{<<"peak_db">> := -9.0},
        <<"microphone">> := #{<<"peak_db">> := -3.0}}},Levels).

native_levels_have_one_row_per_signal_test() ->
    Level=fun(Peak,Age) -> #{peak_db => Peak,rms_db => Peak-3,meter_age_ms => Age} end,
    S=#{instance => binary:copy(<<"A">>,32),revision => 0,audio_view => #{levels =>
        #{microphone => Level(-6.0,0),speaker => Level(-12.0,0),broadcast => Level(-18.0,0)}}},
    ba_test_consent:with(#{inspect => true},fun() ->
        {reply,Local,_}=ba_device_handler:handle_call(status,undefined,S),
        ?assertMatch(#{microphone := #{meter := #{<<"peak_db">> := -6.0}},
            speaker := #{meter := #{<<"peak_db">> := -12.0,<<"meter_stage">> := <<"output_submitted">>}},
            broadcast := #{meter := #{<<"peak_db">> := -18.0}}},maps:get(audio,Local)),
        {reply,Metrics,_}=ba_device_handler:handle_call(capability_metrics,undefined,S),
        ?assertNot(maps:is_key(<<"audio_meters">>,Metrics)),
        ?assertMatch(#{<<"microphone">> := #{<<"peak_db">> := -6.0},<<"speaker">> := #{<<"peak_db">> := -12.0},
            <<"broadcast">> := #{<<"peak_db">> := -18.0}},maps:get(<<"audio">>,Metrics)),
        ?assertNot(maps:is_key(<<"peak_db">>,maps:get(<<"speaker">>,
            maps:get(<<"audio">>,maps:get(monitor,Local))))),
        {reply,Expired,_}=ba_device_handler:handle_call(status,undefined,S#{audio_observed_at => erlang:monotonic_time(millisecond)-1001}),
        ?assertNot(maps:is_key(meter,maps:get(speaker,maps:get(audio,Expired),#{})))
    end).

normal_capabilities_include_label_but_not_metrics_test() ->
    OldName=os:getenv("BA_DEVICE_NAME"),os:putenv("BA_DEVICE_NAME","Test Device"),
    Old=application:get_env(ba_core,audio_automation),application:set_env(ba_core,audio_automation,true),
    try
        S=#{active => #{},enabled => false,instance => binary:copy(<<"A">>,32),revision => 0,
            audio_diagnostics => #{<<"mixer.dropped">> => 3},
            audio => #{broadcast => #{state => running,blocks => 5,frames => 100,
                meter => #{<<"peak_db">> => -3.0,<<"rms_db">> => -6.0,<<"meter_age_ms">> => 1,<<"meter_stage">> => <<"capture">>}}}},
        {reply,Normal,_}=ba_device_handler:handle_call(capabilities,undefined,S),
        %% The label carries the Device type first (Mac, iPhone, ...), see ba_device_label:display/1.
        ?assertEqual(<<(ba_device_label:display(<<"Test Device">>))/binary," | AAAAAAAA">>,maps:get(<<"device_name">>,Normal)),
        ?assertNot(maps:is_key(<<"audio_diagnostics">>,Normal)),
        Entry=maps:get(<<"broadcast">>,maps:get(<<"audio">>,Normal)),
        ?assertEqual([<<"available">>,<<"consent">>,<<"state">>],lists:sort(maps:keys(Entry))),
        {reply,Metrics,_}=ba_test_consent:with(#{inspect => true},
            fun() -> ba_device_handler:handle_call(capability_metrics,undefined,S) end),
        ?assertEqual(maps:get(<<"device_name">>,Normal),maps:get(<<"device_name">>,Metrics)),
        ?assertMatch(#{<<"mixer.dropped">> := 3,<<"diagnostics.analysis">> := true},maps:get(<<"audio_diagnostics">>,Metrics)),
        M=maps:get(<<"broadcast">>,maps:get(<<"audio">>,Metrics)),
        ?assertEqual(-3.0,maps:get(<<"peak_db">>,M)),?assertEqual(100,maps:get(<<"frames">>,M))
    after
        case OldName of false -> os:unsetenv("BA_DEVICE_NAME");_ -> os:putenv("BA_DEVICE_NAME",OldName) end,
        case Old of undefined -> application:unset_env(ba_core,audio_automation);{ok,X} -> application:set_env(ba_core,audio_automation,X) end end.

render_devices_once_with_separators_and_opt_in_color_test() ->
    Id=binary:copy(<<"A">>,64),Other=binary:copy(<<"B">>,64),
    Running=#{<<"state">> => <<"running">>},Disabled=#{<<"state">> => <<"disabled">>},
    Name = <<"Paavo’s iPhone (2)"/utf8>>,
    View=#{<<"session">> => #{<<"name">> => <<"Together">>},<<"state">> => <<"authorized">>,
        <<"devices">> => [#{<<"id">> => Id,<<"name">> => Name,<<"state">> => <<"ok">>,
            <<"capabilities">> => #{<<"audio">> => #{<<"speaker">> => Running,<<"microphone">> => Disabled,<<"broadcast">> => Disabled}}},
            #{<<"id">> => Other,<<"state">> => <<"connecting">>}]},
    Plain=unicode:characters_to_binary(ba_cli_monitor:render(View)),
    ?assertEqual(1,length(binary:matches(Plain,Name))),
    ?assertEqual(nomatch,binary:match(Plain,binary:part(Id,0,12))),
    ?assertEqual(1,length(binary:matches(Plain,binary:part(Other,0,12)))),
    ?assertEqual(2,length(binary:matches(Plain,list_to_binary(lists:duplicate(83,$-))))),
    ?assertEqual(nomatch,binary:match(Plain,<<27>>)),
    Color=unicode:characters_to_binary(ba_cli_monitor:render(View,true)),
    ?assertNotEqual(nomatch,binary:match(Color,<<27,"[32m">>)),
    ?assertNotEqual(nomatch,binary:match(Color,<<27,"[90m">>)).

render_untrusted_device_names_without_terminal_controls_test() ->
    View=#{<<"session">> => #{},<<"state">> => <<"authorized">>,<<"devices">> => [
        #{<<"id">> => binary:copy(<<"A">>,64),<<"name">> => <<"Phone",27,"[2J",10,"spoof">>,<<"state">> => <<"connecting">>}]},
    Text=unicode:characters_to_binary(ba_cli_monitor:render(View)),
    ?assertEqual(nomatch,binary:match(Text,<<27>>)),
    ?assertNotEqual(nomatch,binary:match(Text,<<"Phone?[2J?spoof">>)).

render_channel_error_and_missed_targets_test() ->
    View=#{<<"session">> => #{},<<"state">> => <<"authorized">>,<<"devices">> => [
        #{<<"id">> => binary:copy(<<"A">>,64),<<"state">> => <<"ok">>,<<"capabilities">> => #{
            <<"audio">> => #{<<"speaker">> => #{<<"state">> => <<"error">>,<<"error">> => <<"output_closed">>}},
            <<"audio_diagnostics">> => #{<<"clock.state">> => <<"synchronized">>,<<"mixer.rendered">> => 10,
                <<"mixer.dropped">> => 2,<<"mixer.queued_blocks">> => 5,<<"mixer.clipped_frames">> => 0,
                <<"mixer.failure.missed_packet_target">> => 2}}}]},
    Text=unicode:characters_to_binary(ba_cli_monitor:render(View)),
    ?assertNotEqual(nomatch,binary:match(Text,<<"speaker: output_closed">>)),
    ?assertNotEqual(nomatch,binary:match(Text,<<"mixer.failure.missed_packet_target: 2">>)),
    ?assertNotEqual(nomatch,binary:match(Text,<<"10 rendered  2 dropped  5 queued">>)).

render_engine_counters_and_analysis_off_test() ->
    View=fun(D) -> #{<<"session">> => #{},<<"state">> => <<"authorized">>,<<"devices">> => [
        #{<<"id">> => binary:copy(<<"A">>,64),<<"state">> => <<"ok">>,<<"capabilities">> => #{<<"audio_diagnostics">> => D}}]} end,
    Text=iolist_to_binary(ba_cli_monitor:render(View(#{<<"transport.packets">> => 960,<<"transport.late">> => 2,
        <<"transport.recovered">> => 5,<<"transport.nacks">> => 6,<<"transport.sent">> => 704,<<"transport.retransmits">> => 1}))),
    ?assertNotEqual(nomatch,binary:match(Text,<<"in  960 pkts  2 late">>)),
    ?assertNotEqual(nomatch,binary:match(Text,<<"5/6 recovered">>)),
    ?assertNotEqual(nomatch,binary:match(Text,<<"out 704 sends  1 resent">>)),
    Off=iolist_to_binary(ba_cli_monitor:render(View(#{<<"diagnostics.analysis">> => false,<<"diagnostics.meters">> => false}))),
    ?assertNotEqual(nomatch,binary:match(Off,<<"audio analysis off">>)),
    ?assertEqual(nomatch,binary:match(Off,<<"clock unavailable">>)).
