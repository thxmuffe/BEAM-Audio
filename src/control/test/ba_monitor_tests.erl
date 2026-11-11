-module(ba_monitor_tests).
-include_lib("eunit/include/eunit.hrl").

render_missing_levels_is_not_silence_test() ->
    Id=binary:copy(<<"A">>,64),Entry=#{<<"state">> => <<"running">>,<<"consent">> => true,<<"available">> => true},
    View=#{<<"buffee">> => #{<<"name">> => <<"Test">>,<<"buffee">> => binary:copy(<<"B">>,32)},<<"state">> => <<"authorized">>,
        <<"devices">> => [#{<<"id">> => Id,<<"state">> => <<"ok">>,<<"capabilities">> => #{<<"audio">> => #{<<"broadcast">> => Entry}}}]},
    Text=iolist_to_binary(ba_cli_monitor:render(View)),
    ?assertNotEqual(nomatch,binary:match(Text,<<"N/A">>)),
    ?assertEqual(nomatch,binary:match(Text,<<"-96.0">>)),
    ?assertNotEqual(nomatch,binary:match(Text,<<"running">>)).

capture_meter_age_and_stage_are_explicit_test() ->
    Now=erlang:monotonic_time(millisecond),
    S=(ba_audio_input:new())#{meter => #{<<"peak_db">> => -3.0,<<"rms_db">> => -6.0},last_capture_ms => Now},
    M=maps:get(meter,ba_audio_input:status(S)),
    ?assertEqual(<<"capture">>,maps:get(<<"meter_stage">>,M)),
    ?assertEqual(-3.0,maps:get(<<"peak_db">>,M)),
    Stale=maps:get(meter,ba_audio_input:status(S#{last_capture_ms := Now-1000})),
    ?assert(maps:get(<<"meter_age_ms">>,Stale)>=1000).

normal_capabilities_include_label_but_not_metrics_test() ->
    OldName=os:getenv("BA_DEVICE_NAME"),os:putenv("BA_DEVICE_NAME","Test Device"),
    Old=application:get_env(ba_core,audio_automation),application:set_env(ba_core,audio_automation,true),
    try
        S=#{active => #{},enabled => false,instance => binary:copy(<<"A">>,32),revision => 0,
            audio_diagnostics => #{<<"mixer.dropped">> => 3},
            audio => #{broadcast => #{state => running,blocks => 5,frames => 100,
                meter => #{<<"peak_db">> => -3.0,<<"rms_db">> => -6.0,<<"meter_age_ms">> => 1,<<"meter_stage">> => <<"capture">>}}}},
        {reply,Normal,_}=ba_device_handler:handle_call(capabilities,undefined,S),
        ?assertEqual(<<"Test Device | AAAAAAAA">>,maps:get(<<"device_name">>,Normal)),
        ?assertNot(maps:is_key(<<"audio_diagnostics">>,Normal)),
        Entry=maps:get(<<"broadcast">>,maps:get(<<"audio">>,Normal)),
        ?assertEqual([<<"available">>,<<"consent">>,<<"state">>],lists:sort(maps:keys(Entry))),
        {reply,Metrics,_}=ba_device_handler:handle_call(capability_metrics,undefined,S),
        ?assertEqual(maps:get(<<"device_name">>,Normal),maps:get(<<"device_name">>,Metrics)),
        ?assertEqual(#{<<"mixer.dropped">> => 3},maps:get(<<"audio_diagnostics">>,Metrics)),
        M=maps:get(<<"broadcast">>,maps:get(<<"audio">>,Metrics)),
        ?assertEqual(-3.0,maps:get(<<"peak_db">>,M)),?assertEqual(100,maps:get(<<"frames">>,M))
    after
        case OldName of false -> os:unsetenv("BA_DEVICE_NAME");_ -> os:putenv("BA_DEVICE_NAME",OldName) end,
        case Old of undefined -> application:unset_env(ba_core,audio_automation);{ok,X} -> application:set_env(ba_core,audio_automation,X) end end.

render_devices_once_with_separators_and_opt_in_color_test() ->
    Id=binary:copy(<<"A">>,64),Other=binary:copy(<<"B">>,64),
    Running=#{<<"state">> => <<"running">>},Disabled=#{<<"state">> => <<"disabled">>},
    Name = <<"Paavo’s iPhone (2)"/utf8>>,
    View=#{<<"buffee">> => #{<<"name">> => <<"Together">>},<<"state">> => <<"authorized">>,
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
    View=#{<<"buffee">> => #{},<<"state">> => <<"authorized">>,<<"devices">> => [
        #{<<"id">> => binary:copy(<<"A">>,64),<<"name">> => <<"Phone",27,"[2J",10,"spoof">>,<<"state">> => <<"connecting">>}]},
    Text=unicode:characters_to_binary(ba_cli_monitor:render(View)),
    ?assertEqual(nomatch,binary:match(Text,<<27>>)),
    ?assertNotEqual(nomatch,binary:match(Text,<<"Phone?[2J?spoof">>)).

render_channel_error_and_missed_targets_test() ->
    View=#{<<"buffee">> => #{},<<"state">> => <<"authorized">>,<<"devices">> => [
        #{<<"id">> => binary:copy(<<"A">>,64),<<"state">> => <<"ok">>,<<"capabilities">> => #{
            <<"audio">> => #{<<"speaker">> => #{<<"state">> => <<"error">>,<<"error">> => <<"output_closed">>}},
            <<"audio_diagnostics">> => #{<<"clock.state">> => <<"synchronized">>,<<"mixer.rendered">> => 10,
                <<"mixer.dropped">> => 2,<<"mixer.queued_blocks">> => 5,<<"mixer.clipped_frames">> => 0,
                <<"mixer.failure.missed_packet_target">> => 2}}}]},
    Text=unicode:characters_to_binary(ba_cli_monitor:render(View)),
    ?assertNotEqual(nomatch,binary:match(Text,<<"speaker: output_closed">>)),
    ?assertNotEqual(nomatch,binary:match(Text,<<"mixer.failure.missed_packet_target: 2">>)),
    ?assertNotEqual(nomatch,binary:match(Text,<<"10 rendered  2 dropped  5 queued">>)).
