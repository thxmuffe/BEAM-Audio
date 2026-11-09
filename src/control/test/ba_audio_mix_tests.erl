-module(ba_audio_mix_tests).
-include_lib("eunit/include/eunit.hrl").
new() ->
    S = ba_audio_mix:new(48000,<<"test">>),
    ba_audio_mix:enable(b,true,ba_audio_mix:add(b,1.0,
        ba_audio_mix:enable(a,true,ba_audio_mix:add(a,1.0,S)))).
descriptor(Format,Channels) -> #{encoding => pcm,sample_format => Format,channel_count => Channels,sample_rate => 48000,clock => <<"test">>}.
header(Time,N) -> #{playback_time => Time,frame_count => N}.
sample(PCM) -> [V || <<V:32/little-float>> <= PCM].
mix_mono_and_stereo_different_formats_test() ->
    {ok,A} = ba_audio_mix:push(a,descriptor(pcm16_le,1),header(1000000000,2),<<8192:16/little-signed,8192:16/little-signed>>,0,new()),
    PCM = binary:copy(<<0.5:32/little-float>>,4),
    {ok,B} = ba_audio_mix:push(b,descriptor(float32_le,2),header(1000000000,2),PCM,0,A),
    {H,Out,_} = ba_audio_mix:take(256,B),
    ?assertEqual(1000000000,maps:get(playback_time,H)),?assertEqual(2,maps:get(frame_count,H)),
    ?assertEqual([0.75,0.75,0.75,0.75],sample(Out)).
paused_source_does_not_change_other_target_test() ->
    PCM = binary:copy(<<0.5:32/little-float>>,4),
    {ok,A} = ba_audio_mix:push(a,descriptor(float32_le,2),header(1000000000,2),PCM,0,new()),
    {ok,B} = ba_audio_mix:push(b,descriptor(float32_le,2),header(1000000000,2),PCM,0,A),
    Paused = ba_audio_mix:enable(a,false,B),
    {H,Out,_} = ba_audio_mix:take(256,Paused),
    ?assertEqual(1000000000,maps:get(playback_time,H)),?assertEqual([0.5,0.5,0.5,0.5],sample(Out)).
limiter_and_gain_test() ->
    PCM = <<0.75:32/little-float,0.75:32/little-float>>,
    {ok,A} = ba_audio_mix:push(a,descriptor(float32_le,2),header(1000000000,1),PCM,0,new()),
    {ok,B} = ba_audio_mix:push(b,descriptor(float32_le,2),header(1000000000,1),PCM,0,A),
    {_,Out,Next} = ba_audio_mix:take(256,B),?assertEqual([1.0,1.0],sample(Out)),
    ?assertEqual(1,maps:get(clipped_frames,ba_audio_mix:snapshot(Next))),
    {_,Quiet,_} = ba_audio_mix:take(256,ba_audio_mix:gain(b,0.0,B)),
    ?assertEqual([0.75,0.75],sample(Quiet)).
missing_late_or_wrong_clock_never_gets_retargeted_test() ->
    PCM = <<0.25:32/little-float,0.25:32/little-float>>,D = descriptor(float32_le,2),
    ?assertMatch({error,_,_},ba_audio_mix:push(a,D,#{frame_count => 1},PCM,0,new())),
    ?assertMatch({error,_,_},ba_audio_mix:push(a,D,header(1,1),PCM,2,new())),
    ?assertMatch({error,_,_},ba_audio_mix:push(a,D#{clock := <<"other">>},header(1000000000,1),PCM,0,new())),
    ?assertMatch({error,_,_},ba_audio_mix:push(a,D#{sample_rate := 44100},header(1000000000,1),PCM,0,new())),
    {ok,S} = ba_audio_mix:push(a,D,header(1000000000,1),PCM,0,new()),
    {_,_,Done} = ba_audio_mix:take(256,S),
    ?assertMatch({error,_,_},ba_audio_mix:push(a,D,header(1000000000,1),PCM,0,Done)).

queued_audio_is_discarded_at_its_own_authorization_deadline_test() ->
    D = descriptor(float32_le,2),
    {ok,Mix} = ba_audio_mix:push(a,D,header(1000000000,1),<<0.25:32/little-float,0.25:32/little-float>>,0,new()),
    S = #{mix => Mix,descriptors => #{a => D#{authorization_deadline => erlang:monotonic_time(millisecond)-1}},
          device => undefined,last_error => null},
    {noreply,Next} = ba_audio_mixer:handle_info(render,S),
    ?assertEqual(undefined,maps:get(mix,Next)),?assertEqual(#{},maps:get(descriptors,Next)),
    ?assertEqual(authorization_expired,maps:get(last_error,Next)).

full_offset_two_source_buffer_test_() -> {timeout,30,fun() ->
    %% Thirty seconds, two 20ms sources: virtual time avoids hardware/timer claims.
    PCM = binary:copy(<<0.25:32/little-float>>,1920),D = descriptor(float32_le,2),
    Mix = lists:foldl(fun(N,S) ->
        H = header(1000000000+N*20000000,960),
        {ok,A} = ba_audio_mix:push(a,D,H,PCM,0,S),
        {ok,B} = ba_audio_mix:push(b,D,H,PCM,0,A),B
    end,new(),lists:seq(0,1499)),
    Snap = ba_audio_mix:snapshot(Mix),
    ?assertEqual(23040000,maps:get(queued_bytes,Snap)),
    ?assert(maps:get(queued_bytes,Snap)<maps:get(max_bytes,Snap)),
    Done = drain(Mix,48000,0),
    ?assertEqual(0,maps:get(queued_bytes,ba_audio_mix:snapshot(Done)))
end}.
drain(Mix,Rate,N) ->
    case ba_audio_mix:take(960,Mix) of
        empty -> ?assertEqual(1440000,N),Mix;
        {H,PCM,Next} ->
            ?assertEqual(1000000000+(N*1000000000 div Rate),maps:get(playback_time,H)),
            ?assertEqual(binary:copy(<<0.5:32/little-float>>,1920),PCM),
            drain(Next,Rate,N+maps:get(frame_count,H))
    end.

maximum_block_overlap_and_adjacent_boundaries_test() ->
    D = descriptor(float32_le,2),
    Push = fun(Start,Frames,S) ->
        Time = 1000000000+Start*1000000000 div 48000,
        PCM = binary:copy(<<0.25:32/little-float>>,Frames*2),
        ba_audio_mix:push(a,D,header(Time,Frames),PCM,0,S)
    end,
    {ok,S} = Push(0,4096,new()),
    [?assertMatch({error,overlapping_packet,_},Push(Start,N,S)) ||
        {Start,N} <- [{0,1},{4095,1},{-1,2},{-1,4096}]],
    ?assertMatch({ok,_},Push(4096,1,S)),
    ?assertMatch({ok,_},Push(-4096,4096,S)).
