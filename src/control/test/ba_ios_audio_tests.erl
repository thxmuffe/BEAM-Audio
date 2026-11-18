-module(ba_ios_audio_tests).
-include_lib("eunit/include/eunit.hrl").
-export([id/0,now/0,to_monotonic/1]).

%% Exercise the real mixer and iOS Erlang binding through TCP. The peer replaces
%% only AVAudioEngine: no hardware, UI, Session credentials or live Device.
id() -> <<"ios-output-test">>.
now() -> {ok,erlang:system_time(nanosecond)}.
to_monotonic(T) -> {ok,T-erlang:time_offset(nanosecond)}.

rejection_keeps_output_and_next_target_test_() ->
    [{atom_to_list(Reason),fun() -> fixture(fun(L,Mixer,D) ->
        Parent=self(),
        {Peer,Ref}=spawn_monitor(fun() ->
            {ok,S}=gen_tcp:accept(L,2000),
            try handshake(S),
                {ok,<<2,Host:64,Frames:32,PCM/binary>>}=gen_tcp:recv(S,0,2000),
                Parent ! {written,Host,Frames,PCM},ok=gen_tcp:send(S,<<5,Code>>),
                {ok,NextPacket}=gen_tcp:recv(S,0,2000),Parent ! {next_packet,NextPacket},
                ok=gen_tcp:send(S,<<5,Code>>),
                {ok,<<4>>}=gen_tcp:recv(S,0,2000),ok=gen_tcp:send(S,<<4>>)
            after gen_tcp:close(S) end
        end),
        ok=ba_audio_mixer:add(music,D,1.0),ok=ba_audio_mixer:enable(music,true),
        {ba_ios_audio,Handle}=maps:get(device,sys:get_state(Mixer)),
        ?assertEqual({ok,[{nodelay,true}]},inet:getopts(maps:get(socket,Handle),[nodelay])),
        {ok,Time}=?MODULE:now(),Target=Time+50000000,
        PCM=binary:copy(<<0.25:32/little-float,0.25:32/little-float>>,256),
        ba_audio_mixer:push(music,D,#{playback_time => Target,frame_count => 256},PCM),
        receive {written,Host,256,Planar} ->
            %% Sample-grid rounding is the mixer's existing conversion. The
            %% adapter must preserve it exactly; it must not retime the packet.
            Grid=(Target*48000+500000000) div 1000000000,
            {ok,Mono}=to_monotonic(Grid*1000000000 div 48000),
            ?assertEqual(Mono+maps:get(host_offset,Handle),Host),
            ?assertEqual(binary:copy(<<0.25:32/little-float>>,512),Planar)
        after 2000 -> error(no_pcm_write) end,
        wait_drops(1,Reason,100),
        ?assertMatch(#{device := {ba_ios_audio,Handle}},sys:get_state(Mixer)),
        ?assertNot(maps:get(output_stop_pending,ba_audio_mixer:status())),
        {ok,NextTime}=?MODULE:now(),NextTarget=NextTime+50000000,
        ba_audio_mixer:push(music,D,#{playback_time => NextTarget,frame_count => 256},PCM),
        receive {next_packet,<<2,NextHost:64,256:32,_/binary>>} ->
            NextGrid=(NextTarget*48000+500000000) div 1000000000,
            {ok,NextMono}=to_monotonic(NextGrid*1000000000 div 48000),
            ?assertEqual(NextMono+maps:get(host_offset,Handle),NextHost)
        after 2000 -> error(no_output_after_rejection) end,
        %% A second error must arrive too: active-once must be rearmed.
        wait_drops(2,Reason,100),
        receive {audio_output_failed,Mixer,_} -> error(output_destroyed) after 0 -> ok end,
        ok=ba_audio_mixer:remove(music),
        receive {'DOWN',Ref,process,Peer,normal} -> ok after 2000 -> error(peer_failed) end
    end) end} || {Code,Reason} <- [{1,native_late_packet},{2,native_target_out_of_bounds},{3,native_output_queue_full}]].

eof_does_not_fake_stop_or_reuse_dead_output_test() -> fixture(fun(L,Mixer,D) ->
    Parent=self(),
    {Peer,Ref}=spawn_monitor(fun() ->
        {ok,S}=gen_tcp:accept(L,2000),handshake(S),
        receive close_peer -> gen_tcp:close(S),Parent ! peer_closed end
    end),
    ok=ba_audio_mixer:add(music,D,1.0),ok=ba_audio_mixer:enable(music,true),
    Peer ! close_peer,
    receive peer_closed -> ok after 2000 -> error(peer_not_closed) end,
    receive {audio_output_failed,Mixer,output_closed} -> ok after 2000 -> error(no_closure) end,
    ?assert(maps:get(output_stop_pending,ba_audio_mixer:status())),
    ok=ba_audio_mixer:add(music,D,1.0),
    ?assertEqual({error,native_stop_unconfirmed},ba_audio_mixer:enable(music,true)),
    receive {'DOWN',Ref,process,Peer,normal} -> ok after 2000 -> error(peer_failed) end
end).

wait_drops(_,_,0) -> error(no_native_drop);
wait_drops(N,Reason,Tries) ->
    case ba_audio_mixer:status() of
        #{diagnostics := #{counts := #{Reason := N}}} -> ok;
        _ -> receive after 5 -> wait_drops(N,Reason,Tries-1) end
    end.
handshake(S) ->
    {ok,<<1,48000:32,2:16>>}=gen_tcp:recv(S,0,2000),ok=gen_tcp:send(S,<<1>>),
    {ok,<<3>>}=gen_tcp:recv(S,0,2000),
    Host=erlang:monotonic_time(nanosecond)+1000000000000000000,
    ok=gen_tcp:send(S,<<3,Host:64,0:64>>).
fixture(Fun) ->
    Old=[{K,application:get_env(ba_core,K)} || K <- [runtime_profile,audio_clock_adapter,audio_output_adapter]],
    PortEnv=os:getenv("BA_AUDIO_PORT"),
    application:set_env(ba_core,runtime_profile,legacy_apps),
    application:set_env(ba_core,audio_clock_adapter,?MODULE),
    application:set_env(ba_core,audio_output_adapter,ba_ios_audio),
    {ok,L}=gen_tcp:listen(0,[binary,{packet,4},{active,false},{nodelay,true},{ip,{127,0,0,1}}]),
    {ok,{_,Port}}=inet:sockname(L),os:putenv("BA_AUDIO_PORT",integer_to_list(Port)),
    {ok,Mixer}=ba_audio_mixer:start_link(),
    D=#{sample_rate => 48000,channel_count => 2,sample_format => float32_le,clock => id(),
        authorization_deadline => erlang:monotonic_time(millisecond)+10000},
    try Fun(L,Mixer,D) after
        gen_server:stop(Mixer),gen_tcp:close(L),
        [case V of undefined -> application:unset_env(ba_core,K);{ok,Value} -> application:set_env(ba_core,K,Value) end || {K,V} <- Old],
        case PortEnv of false -> os:unsetenv("BA_AUDIO_PORT");_ -> os:putenv("BA_AUDIO_PORT",PortEnv) end
    end.

native_output_summary_is_optional_and_rearms_socket_test() ->
    {ok,L}=gen_tcp:listen(0,[binary,{packet,4},{active,false},{ip,{127,0,0,1}}]),
    {ok,{_,Port}}=inet:sockname(L),
    {ok,Client}=gen_tcp:connect({127,0,0,1},Port,[binary,{packet,4},{active,false}]),
    {ok,Server}=gen_tcp:accept(L),
    Handle=#{socket => Client,diagnostics_supported => true},
    try
        ?assertEqual(pending,ba_ios_audio:diagnostics(Handle,#{<<"analysis">> => true})),
        ?assertEqual({ok,<<6,1>>},gen_tcp:recv(Server,0,100)),
        ?assertEqual({ok,<<7>>},gen_tcp:recv(Server,0,100)),
        Packet = <<7,1,1,1,500:16,48000:32,2:16,1000000:64,960:64,704:64,1:32,2:64,5:64,1000:64,2000:64>>,
        {diagnostics,Stats}=ba_ios_audio:event(Handle,{tcp,Client,Packet}),
        ?assertMatch(#{completed_frames := 704,queued_buffers := 1,route := speaker,volume_milli := 500},Stats),
        ok=gen_tcp:send(Server,Packet),
        receive {tcp,Client,Packet} -> ok after 1000 -> error(socket_not_rearmed) end,
        ?assertMatch({ok,#{supported := true}},ba_ios_audio:diagnostics(Handle,#{<<"analysis">> => false})),
        ?assertEqual({ok,<<6,0>>},gen_tcp:recv(Server,0,100)),
        ?assertEqual(unsupported,ba_ios_audio:diagnostics(#{socket => Client},#{<<"analysis">> => true}))
    after gen_tcp:close(Client),gen_tcp:close(Server),gen_tcp:close(L) end.
