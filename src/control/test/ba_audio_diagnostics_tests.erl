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
