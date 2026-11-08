-module(parvi_audio_mix_tests).
-include_lib("eunit/include/eunit.hrl").
new() ->
    S = parvi_audio_mix:new(48000,<<"test">>),
    parvi_audio_mix:enable(b,true,parvi_audio_mix:add(b,1.0,
        parvi_audio_mix:enable(a,true,parvi_audio_mix:add(a,1.0,S)))).
descriptor(Format,Channels) -> #{encoding => pcm,sample_format => Format,channel_count => Channels,sample_rate => 48000,clock => <<"test">>}.
header(Time,N) -> #{playback_time => Time,frame_count => N}.
sample(PCM) -> [V || <<V:32/little-float>> <= PCM].
mix_mono_and_stereo_different_formats_test() ->
    {ok,A} = parvi_audio_mix:push(a,descriptor(pcm16_le,1),header(1000000000,2),<<8192:16/little-signed,8192:16/little-signed>>,0,new()),
    PCM = binary:copy(<<0.5:32/little-float>>,4),
    {ok,B} = parvi_audio_mix:push(b,descriptor(float32_le,2),header(1000000000,2),PCM,0,A),
    {H,Out,_} = parvi_audio_mix:take(256,B),
    ?assertEqual(1000000000,maps:get(playback_time,H)),?assertEqual(2,maps:get(frame_count,H)),
    ?assertEqual([0.75,0.75,0.75,0.75],sample(Out)).
paused_source_does_not_change_other_target_test() ->
    PCM = binary:copy(<<0.5:32/little-float>>,4),
    {ok,A} = parvi_audio_mix:push(a,descriptor(float32_le,2),header(1000000000,2),PCM,0,new()),
    {ok,B} = parvi_audio_mix:push(b,descriptor(float32_le,2),header(1000000000,2),PCM,0,A),
    Paused = parvi_audio_mix:enable(a,false,B),
    {H,Out,_} = parvi_audio_mix:take(256,Paused),
    ?assertEqual(1000000000,maps:get(playback_time,H)),?assertEqual([0.5,0.5,0.5,0.5],sample(Out)).
limiter_and_gain_test() ->
    PCM = <<0.75:32/little-float,0.75:32/little-float>>,
    {ok,A} = parvi_audio_mix:push(a,descriptor(float32_le,2),header(1000000000,1),PCM,0,new()),
    {ok,B} = parvi_audio_mix:push(b,descriptor(float32_le,2),header(1000000000,1),PCM,0,A),
    {_,Out,Next} = parvi_audio_mix:take(256,B),?assertEqual([1.0,1.0],sample(Out)),
    ?assertEqual(1,maps:get(clipped_frames,parvi_audio_mix:snapshot(Next))),
    {_,Quiet,_} = parvi_audio_mix:take(256,parvi_audio_mix:gain(b,0.0,B)),
    ?assertEqual([0.75,0.75],sample(Quiet)).
missing_late_or_wrong_clock_never_gets_retargeted_test() ->
    PCM = <<0.25:32/little-float,0.25:32/little-float>>,D = descriptor(float32_le,2),
    ?assertMatch({error,_,_},parvi_audio_mix:push(a,D,#{frame_count => 1},PCM,0,new())),
    ?assertMatch({error,_,_},parvi_audio_mix:push(a,D,header(1,1),PCM,2,new())),
    ?assertMatch({error,_,_},parvi_audio_mix:push(a,D#{clock := <<"other">>},header(1000000000,1),PCM,0,new())),
    ?assertMatch({error,_,_},parvi_audio_mix:push(a,D#{sample_rate := 44100},header(1000000000,1),PCM,0,new())),
    {ok,S} = parvi_audio_mix:push(a,D,header(1000000000,1),PCM,0,new()),
    {_,_,Done} = parvi_audio_mix:take(256,S),
    ?assertMatch({error,_,_},parvi_audio_mix:push(a,D,header(1000000000,1),PCM,0,Done)).

queued_audio_is_discarded_at_its_own_authorization_deadline_test() ->
    D = descriptor(float32_le,2),
    {ok,Mix} = parvi_audio_mix:push(a,D,header(1000000000,1),<<0.25:32/little-float,0.25:32/little-float>>,0,new()),
    S = #{mix => Mix,descriptors => #{a => D#{authorization_deadline => erlang:monotonic_time(millisecond)-1}},
          device => undefined,last_error => null},
    {noreply,Next} = parvi_audio_mixer:handle_info(render,S),
    ?assertEqual(undefined,maps:get(mix,Next)),?assertEqual(#{},maps:get(descriptors,Next)),
    ?assertEqual(authorization_expired,maps:get(last_error,Next)).
