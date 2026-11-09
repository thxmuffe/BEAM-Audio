-module(ba_monitor_tests).
-include_lib("eunit/include/eunit.hrl").

render_missing_levels_is_not_silence_test() ->
    Id=binary:copy(<<"A">>,64),Entry=#{<<"state">> => <<"running">>,<<"consent">> => true,<<"available">> => true},
    View=#{<<"swarm">> => #{<<"name">> => <<"Test">>,<<"swarm">> => binary:copy(<<"B">>,32)},<<"state">> => <<"authorized">>,
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

normal_capability_shape_stays_unchanged_test() ->
    Old=application:get_env(ba_core,audio_automation),application:set_env(ba_core,audio_automation,true),
    try
        S=#{active => #{},enabled => false,instance => binary:copy(<<"A">>,32),revision => 0,
            audio => #{broadcast => #{state => running,blocks => 5,frames => 100,
                meter => #{<<"peak_db">> => -3.0,<<"rms_db">> => -6.0,<<"meter_age_ms">> => 1,<<"meter_stage">> => <<"capture">>}}}},
        {reply,Normal,_}=ba_device_handler:handle_call(capabilities,undefined,S),
        Entry=maps:get(<<"broadcast">>,maps:get(<<"audio">>,Normal)),
        ?assertEqual([<<"available">>,<<"consent">>,<<"state">>],lists:sort(maps:keys(Entry))),
        {reply,Metrics,_}=ba_device_handler:handle_call(capability_metrics,undefined,S),
        M=maps:get(<<"broadcast">>,maps:get(<<"audio">>,Metrics)),
        ?assertEqual(-3.0,maps:get(<<"peak_db">>,M)),?assertEqual(100,maps:get(<<"frames">>,M))
    after case Old of undefined -> application:unset_env(ba_core,audio_automation);{ok,X} -> application:set_env(ba_core,audio_automation,X) end end.
