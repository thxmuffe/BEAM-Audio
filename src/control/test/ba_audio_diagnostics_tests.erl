-module(ba_audio_diagnostics_tests).
-include_lib("eunit/include/eunit.hrl").
projection_exposes_existing_failures_without_payloads_test() ->
    Transport=#{role => receiver,open => true,received => 20,rejected => 2,private => <<"SECRET">>,
        diagnostics => #{counts => #{invalid_timing => 2}}},
    Audio=#{rejected => 1,publications => 0,
        subscriptions => #{a => #{transport => Transport,pcm => <<"SECRET">>}},
        mixer => #{rendered => 15,dropped => 3,queued_blocks => 4,clipped_frames => 0,output_stop_pending => true,
            diagnostics => #{counts => #{missed_packet_target => 3},last_error => missed_packet_target}}},
    Clock=#{state => synchronized,remaining_correction_ns => -1000,
        filter_reset_reason => network_changed,filter_reset_count => 3,
        filtered_utc_time => 1794257201412688917,offset_policy => #{offset_ms => 1000,ready => true}},
    D=ba_audio_diagnostics:snapshot(Audio,Clock),
    ?assertEqual(ok,ba_audio_diagnostics:validate(D)),
    ?assertEqual(3,maps:get(<<"mixer.failure.missed_packet_target">>,D)),
    ?assertEqual(true,maps:get(<<"mixer.output_stop_pending">>,D)),
    ?assertEqual(2,maps:get(<<"transport.failure.invalid_timing">>,D)),
    ?assertEqual(20,maps:get(<<"transport.received">>,D)),
    ?assertEqual(<<"network_changed">>,maps:get(<<"clock.filter_reset_reason">>,D)),
    ?assertEqual(3,maps:get(<<"clock.filter_reset_count">>,D)),
    ?assertEqual(-1000,maps:get(<<"clock.remaining_correction_ns">>,D)),
    ?assertEqual(<<"synchronized">>,maps:get(<<"clock.state">>,D)),
    ?assertEqual(nomatch,binary:match(iolist_to_binary(json:encode(D)),<<"SECRET">>)),
    ?assertNot(maps:is_key(<<"clock.filtered_utc_time">>,D)).

subscription_intent_does_not_imply_open_media_test() ->
    Subs=#{waiting => #{state => waiting_for_source,transport => #{}},
        opening => #{state => opening,transport => #{role => receiver,open => false}},
        unresponsive => #{state => active,transport => #{error => unavailable}},
        receiving => #{state => active,mix_ready => true,transport => #{role => receiver,open => true}}},
    D=ba_audio_diagnostics:snapshot(#{subscriptions => Subs,suspended => false},#{}),
    ?assertEqual(ok,ba_audio_diagnostics:validate(D)),
    ?assertEqual(4,maps:get(<<"receiver.subscriptions">>,D)),
    ?assertEqual(3,maps:get(<<"transport.sessions">>,D)),
    ?assertEqual(1,maps:get(<<"transport.open">>,D)),
    ?assertEqual(2,maps:get(<<"receiver.active_subscriptions">>,D)),
    ?assertEqual(1,maps:get(<<"receiver.mix_ready_subscriptions">>,D)),
    ?assertEqual(false,maps:get(<<"receiver.suspended">>,D)).
wire_rejects_unbounded_or_nested_diagnostics_test() ->
    ?assertException(error,_,ba_audio_diagnostics:validate(#{<<"mixer.dropped">> => #{pcm => <<"audio">>}})),
    ?assertException(error,_,ba_audio_diagnostics:validate(#{<<"mixer.dropped">> => 9007199254740992})),
    ?assertException(error,_,ba_audio_diagnostics:validate(#{<<"secret">> => <<"private">>})),
    ?assertException(error,_,ba_audio_diagnostics:validate(#{<<"clock.state">> => <<27,"[2J">>})).

raw_clock_offset_retains_nanoseconds_as_a_canonical_string_test() ->
    D=ba_audio_diagnostics:snapshot(#{},#{raw_offset_ns => <<"2371425727177476982">>,estimate_quality => provisional}),
    ?assertEqual(<<"2371425727177476982">>,maps:get(<<"clock.raw_offset_ns">>,D)),
    ?assertEqual(<<"provisional">>,maps:get(<<"clock.estimate_quality">>,D)),
    ?assertEqual(ok,ba_audio_diagnostics:validate(D)),
    ?assertException(error,_,ba_audio_diagnostics:validate(#{<<"clock.raw_offset_ns">> => <<"01">>})).

%% Inspection follows calibration consent; without it no work is done and no
%% stale levels are reported. (The secure profile with no consent granted.)
calibration_consent_gates_inspection_test() ->
    Old=application:get_env(ba_core,runtime_profile),
    try
        application:set_env(ba_core,runtime_profile,buffee_control),
        ?assertEqual(#{<<"diagnostics.meters">> => false,<<"diagnostics.analysis">> => false},
            ba_audio_diagnostics:snapshot(#{mixer => #{rendered => 10}},#{state => synchronized})),
        ?assertEqual(#{<<"meters">> => false,<<"analysis">> => false,<<"microphone">> => false},ba_audio_diagnostics:options()),
        application:unset_env(ba_core,runtime_profile), % compatibility profile: allowed
        ?assertEqual(true,ba_audio_diagnostics:enabled(analysis)),
        ?assertException(error,_,ba_audio_diagnostics:validate_options(#{<<"meters">> => <<"yes">>})),
        ?assertException(error,_,ba_audio_diagnostics:validate_options(#{<<"pcm">> => true}))
    after case Old of undefined -> application:unset_env(ba_core,runtime_profile);{ok,V} -> application:set_env(ba_core,runtime_profile,V) end end.

native_summary_is_allowlisted_not_arbitrary_state_test() ->
    D=ba_audio_diagnostics:snapshot(#{mixer => #{submitted_frames => 48000,output => #{
        supported => true,backend => ios,completed_frames => 47900,route => speaker,
        engine_running => true,player_running => true,private => <<"SECRET">>}}},#{}),
    ?assertEqual(ok,ba_audio_diagnostics:validate(D)),
    ?assertEqual(47900,maps:get(<<"output.completed_frames">>,D)),
    ?assertEqual(48000,maps:get(<<"mixer.submitted_frames">>,D)),
    ?assertNot(maps:is_key(<<"output.private">>,D)).

recent_failures_are_bounded_and_payload_free_test() ->
    S=lists:foldl(fun(_,Acc) -> ba_diagnostics:count(missed_packet_target,Acc) end,#{},lists:seq(1,100)),
    %% The shared local snapshots also serialize this view, not just the signed projection.
    ?assert(is_list(json:encode(ba_diagnostics:view(S)))),
    Trace=ba_audio_diagnostics:trace(#{mixer => #{diagnostics => ba_diagnostics:view(S)}}),
    ?assertEqual(16,map_size(Trace)),?assertEqual(ok,ba_audio_diagnostics:validate_trace(Trace)),
    ?assertMatch(#{<<"1">> := #{<<"stage">> := <<"mixer">>,<<"reason">> := <<"missed_packet_target">>}},Trace),
    ?assertException(error,_,ba_audio_diagnostics:validate_trace(Trace#{<<"17">> => maps:get(<<"1">>,Trace)})),
    ?assertException(error,_,ba_audio_diagnostics:validate_trace(#{<<"1">> => #{<<"stage">> => <<"mixer">>,<<"reason">> => <<"bad">>,<<"age_ms">> => 0,<<"pcm">> => <<0>>}})).
