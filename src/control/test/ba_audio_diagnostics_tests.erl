-module(ba_audio_diagnostics_tests).
-include_lib("eunit/include/eunit.hrl").
projection_exposes_existing_failures_without_payloads_test() ->
    Transport=#{received => 20,rejected => 2,private => <<"SECRET">>,
        diagnostics => #{counts => #{invalid_timing => 2}}},
    Audio=#{rejected => 1,publications => 0,
        subscriptions => #{a => #{transport => Transport,pcm => <<"SECRET">>}},
        mixer => #{rendered => 15,dropped => 3,queued_blocks => 4,clipped_frames => 0,
            diagnostics => #{counts => #{missed_packet_target => 3},last_error => missed_packet_target}}},
    Clock=#{state => synchronized,remaining_correction_ns => -1000,
        filtered_utc_time => 1794257201412688917,offset_policy => #{offset_ms => 1000,ready => true}},
    D=ba_audio_diagnostics:snapshot(Audio,Clock),
    ?assertEqual(ok,ba_audio_diagnostics:validate(D)),
    ?assertEqual(3,maps:get(<<"mixer.failure.missed_packet_target">>,D)),
    ?assertEqual(2,maps:get(<<"transport.failure.invalid_timing">>,D)),
    ?assertEqual(20,maps:get(<<"transport.received">>,D)),
    ?assertEqual(-1000,maps:get(<<"clock.remaining_correction_ns">>,D)),
    ?assertEqual(<<"synchronized">>,maps:get(<<"clock.state">>,D)),
    ?assertEqual(nomatch,binary:match(iolist_to_binary(json:encode(D)),<<"SECRET">>)),
    ?assertNot(maps:is_key(<<"clock.filtered_utc_time">>,D)).
wire_rejects_unbounded_or_nested_diagnostics_test() ->
    ?assertException(error,_,ba_audio_diagnostics:validate(#{<<"mixer.dropped">> => #{pcm => <<"audio">>}})),
    ?assertException(error,_,ba_audio_diagnostics:validate(#{<<"mixer.dropped">> => 9007199254740992})),
    ?assertException(error,_,ba_audio_diagnostics:validate(#{<<"secret">> => <<"private">>})),
    ?assertException(error,_,ba_audio_diagnostics:validate(#{<<"clock.state">> => <<27,"[2J">>})).
