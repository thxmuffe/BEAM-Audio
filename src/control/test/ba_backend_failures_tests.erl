-module(ba_backend_failures_tests).
-compile({no_auto_import,[now/0]}).
-include_lib("eunit/include/eunit.hrl").
-export([id/0,now/0,to_monotonic/1,from_monotonic/1,write/4,close/1]).
id() -> <<"test">>.
now() -> {ok,erlang:system_time(nanosecond)}.
to_monotonic(T) -> {ok,T-erlang:time_offset(nanosecond)}.
from_monotonic(T) -> {ok,T+erlang:time_offset(nanosecond)}.
write(_,Time,Frames,_) -> put(written_span,{Time,Frames}),ok.
close(_) -> ok.

same_contract_is_a_noop_and_stale_revision_is_rejected_test() ->
    Peer = binary:copy(<<"A">>,64),Id = binary:copy(<<"B">>,32),Key = {receive_audio,Peer,<<"music">>},
    S = #{contracts => #{Key => #{id => Id,revision => 2}},subscriptions => retained_media_and_buffers},
    ?assertEqual({reply,ok,S},ba_audio_receiver:handle_call({contract,receive_audio,Peer,<<"music">>,Id,2},undefined,S)),
    ?assertEqual({reply,{error,stale_contract},S},ba_audio_receiver:handle_call({contract,receive_audio,Peer,<<"music">>,Id,1},undefined,S)).

failure_counters_are_bounded_and_payload_free_test() ->
    S = lists:foldl(fun(N,Acc) -> ba_diagnostics:count({malformed,<<N:32>>},Acc) end,#{},lists:seq(1,100)),
    ?assertEqual(#{counts => #{invalid_or_unsupported => 100},last_error => invalid_or_unsupported},ba_diagnostics:view(S)),
    T = ba_diagnostics:count(missed_packet_target,S),
    ?assertMatch(#{counts := #{missed_packet_target := 1},last_error := missed_packet_target},ba_diagnostics:view(T)).

packet_failure_reasons_are_distinct_test() ->
    D = #{encoding => pcm,sample_format => float32_le,sample_rate => 48000,channel_count => 2,clock => <<"test">>},
    H = #{playback_time => 1000000000,frame_count => 1},PCM = <<0.25:32/little-float,0.25:32/little-float>>,
    Mix = ba_audio_mix:enable(a,true,ba_audio_mix:add(a,1.0,ba_audio_mix:new(48000,<<"test">>))),
    ?assertMatch({error,missing_presentation_target,_},ba_audio_mix:push(a,D,#{frame_count => 1},PCM,0,Mix)),
    ?assertMatch({error,late_packet,_},ba_audio_mix:push(a,D,H,PCM,2000000000,Mix)),
    ?assertMatch({error,target_too_far,_},ba_audio_mix:push(a,D,H#{playback_time := 32000000000},PCM,0,Mix)),
    ?assertMatch({error,buffer_full,_},ba_audio_mix:push(a,D,H,PCM,0,Mix#{queued_bytes := 33554432})),
    {ok,Queued} = ba_audio_mix:push(a,D,H,PCM,0,Mix),
    ?assertMatch({error,overlapping_packet,_},ba_audio_mix:push(a,D,H,PCM,0,Queued)).

pcm_owner_overload_is_visible_without_retargeting_test() ->
    Owner = spawn(fun() -> receive stop -> ok end end),
    try
        [Owner ! queued || _ <- lists:seq(1,64)],
        D = #{encoding => pcm,sample_format => float32_le,sample_rate => 48000,channel_count => 2,clock => <<"test">>},
        {ok,Packet} = ba_audio_packet:encode(channel,D,#{playback_time => 1000000000,sequence => 0,channel_id => 0},<<0.25:32/little-float,0.25:32/little-float>>),
        S = #{owner => Owner,pc => pc,channel => channel,role => receiver,open => true,
            context => #{deadline => erlang:monotonic_time(millisecond)+10000},descriptor => D,
            last_sequence => undefined,received => 0,rejected => 0},
        {noreply,Next} = ba_media_session:handle_info({ex_webrtc,pc,{data,channel,Packet}},S),
        ?assertEqual(1,maps:get(received,Next)),
        ?assertMatch(#{counts := #{owner_mailbox_overloaded := 1}},ba_diagnostics:view(Next))
    after exit(Owner,kill) end.

otp_reports_do_not_include_pcm_test() ->
    Audio = <<"private-sample-block">>,Status = #{state => #{mix => Audio},message => Audio,log => [Audio]},
    [?assertEqual(nomatch,binary:match(term_to_binary(Report),Audio)) || Report <-
        [ba_audio_mixer:format_status(Status),ba_audio_source:format_status(Status),
         ba_mac_audio:format_status(Status),ba_mac_output:format_status(Status)]].

future_buffering_does_not_allow_output_past_authorization_test() ->
    Old = application:get_env(ba_core,audio_clock_adapter),application:set_env(ba_core,audio_clock_adapter,?MODULE),
    try
        {ok,UTC} = now(),{ok,Mono} = to_monotonic(UTC),Target = UTC+1000000000,
        Deadline = erlang:monotonic_time(millisecond)+1004,
        D = #{encoding => pcm,sample_format => float32_le,sample_rate => 48000,channel_count => 2,clock => id(),authorization_deadline => Deadline},
        Mix = ba_audio_mix:enable(a,true,ba_audio_mix:add(a,1.0,ba_audio_mix:new(48000,id()))),
        S = #{mix => Mix,descriptors => #{a => D},device => {?MODULE,#{latency_ns => 985000000}},dropped => 0,rendered => 0,last_error => null},
        H = #{playback_time => Target,frame_count => 960},PCM = binary:copy(<<0.25:32/little-float>>,1920),
        {noreply,Buffered} = ba_audio_mixer:handle_cast({packet,a,D,H,PCM},S),
        ?assertEqual(0,maps:get(dropped,Buffered)),
        {noreply,_} = ba_audio_mixer:handle_info(render,Buffered),
        {Handoff,Frames} = get(written_span),
        ?assert(Frames>0 andalso Frames<256),
        ?assert(Handoff+985000000+Frames*1000000000 div 48000=<Deadline*1000000),
        ?assert(Handoff>Mono),
        Expired = Buffered#{descriptors := #{a => D#{authorization_deadline := erlang:monotonic_time(millisecond)-1}}},
        {noreply,Stopped} = ba_audio_mixer:handle_info(render,Expired),
        ?assertEqual(undefined,maps:get(mix,Stopped))
    after
        erase(written_span),case Old of undefined -> application:unset_env(ba_core,audio_clock_adapter);{ok,V} -> application:set_env(ba_core,audio_clock_adapter,V) end
    end.
