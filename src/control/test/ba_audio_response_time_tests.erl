-module(ba_audio_response_time_tests).
-include_lib("eunit/include/eunit.hrl").

average_lateness_is_added_to_current_response_time_test() ->
    P=#{revision => 4,offset_ms => 300,automatic => false},
    A=ba_audio_response_time:add(20000000,P,#{}),
    ?assertEqual(none,ba_audio_response_time:summary(A)),
    B=ba_audio_response_time:add(80000000,P,A),
    R=ba_audio_response_time:summary(B),
    ?assertMatch(#{discarded := 2,mean_late_ms := 50,required_ms := 350,response_ms := 300},R),
    ?assertNotEqual(nomatch,binary:match(ba_audio_response_time:text(R),<<"350 ms">>)),
    %% Measurements from another Response time cannot compound an old delta.
    ?assertEqual(none,ba_audio_response_time:summary(ba_audio_response_time:add(1000000,P#{revision := 5,offset_ms := 800},B))).

unknown_native_lateness_is_never_guessed_test() ->
    P=#{revision => 1,offset_ms => 150},
    R=ba_audio_response_time:summary(ba_audio_response_time:add(unknown,P,ba_audio_response_time:add(unknown,P,#{}))),
    ?assertMatch(#{discarded := 2},R),?assertNot(maps:is_key(required_ms,R)),
    One=ba_audio_response_time:summary(ba_audio_response_time:add(1000000,P,ba_audio_response_time:add(unknown,P,#{}))),
    ?assertNot(maps:is_key(required_ms,One)).


automatic_increases_taper_and_never_jump_to_three_seconds_test() ->
    Changes=[ba_audio_response_time:increase(C,C+100)-C || C <- [300,600,1000,2000,2900]],
    ?assertEqual([75,33,14,1,0],Changes),
    ?assertEqual(800,ba_audio_response_time:increase(800,700)),
    ?assert(ba_audio_response_time:increase(150,30000)<450),
    End=lists:foldl(fun(_,C) -> ba_audio_response_time:increase(C,30000) end,150,lists:seq(1,10000)),
    ?assert(End<3000),?assertEqual(3000,ba_audio_response_time:increase(3000,30000)).
