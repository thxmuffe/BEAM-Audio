-module(parvi_audio_restore_events_tests).
-include_lib("eunit/include/eunit.hrl").

source_description_restores_during_discovery_cooldown_test() ->
    with_runtime(fun(S,Source,D) ->
        {noreply,Waiting} = parvi_audio_receiver:handle_info({parvi_changed,clock},S),
        ?assert(maps:get(discover_at,Waiting) > erlang:monotonic_time(millisecond)),
        ?assertEqual(maps:get(retry_at,S),maps:get(retry_at,Waiting)),
        Requests = gen_server:send_request(Source,describe,Source,gen_server:reqids_new()),
        Reply = receive M -> M after 1000 -> error(no_description) end,
        Pending = Waiting#{offers := #{Source => #{id => <<"source">>}},requests => Requests},
        {noreply,Opening} = parvi_audio_receiver:handle_info(Reply,Pending),
        assert_opening(Opening,Source),
        ?assertEqual(#{channel => D},maps:get(profiles,maps:get(Source,maps:get(offers,Opening))))
    end).

fresh_clock_restores_immediately_and_only_once_test() ->
    with_runtime(fun(S,Source,D) ->
        Now = erlang:monotonic_time(nanosecond),
        ets:insert(parvi_clock,{clock,clock(Now-1)}),
        Offered = S#{resume_after := Now,offers := #{Source => offer(D)},
            discover_at => erlang:monotonic_time(millisecond)+5000},
        ?assertEqual({noreply,Offered},parvi_audio_receiver:handle_info({parvi_changed,clock},Offered)),
        ets:insert(parvi_clock,{clock,clock(Now+1)}),
        {noreply,Opening} = parvi_audio_receiver:handle_info({parvi_changed,clock},Offered),
        assert_opening(Opening,Source),
        ?assertEqual({noreply,Opening},parvi_audio_receiver:handle_info({parvi_changed,clock},Opening))
    end).

readiness_events_preserve_failure_backoff_and_suspension_test() ->
    with_runtime(fun(S,Source,D) ->
        Offered = S#{offers := #{Source => offer(D)}},
        Cooldown = Offered#{retry_at := erlang:monotonic_time(millisecond)+5000},
        ?assertEqual({noreply,Cooldown},parvi_audio_receiver:handle_info({parvi_changed,clock},Cooldown)),
        Paused = Offered#{suspended := true},
        ?assertEqual({noreply,Paused},parvi_audio_receiver:handle_info({parvi_changed,clock},Paused)),
        receive {opened,_} -> error(unexpected_open) after 0 -> ok end
    end).

clock(Sync) -> #{role => follower,filter_ready => true,last_sync => Sync,age_ns => 0}.
offer(D) -> #{id => <<"source">>,name => <<"Music">>,source_key => <<"default-output">>,profiles => #{channel => D}}.
assert_opening(S,Source) ->
    ?assertMatch(#{state := opening,session := P} when is_pid(P),maps:get(receive_state,S)),
    receive {opened,Source} -> ok after 1000 -> error(not_opened) end.

%% Exercise the real restore/description code, substituting only the supervisor
%% session-start boundary. No network, native device or sleep-based retry needed.
with_runtime(Fun) ->
    ets:new(parvi_cluster_trust,[named_table]),ets:new(parvi_clock,[named_table]),
    Parent = self(),
    D = #{encoding => pcm,sample_format => float32_le,sample_rate => 48000,
        channel_count => 2,clock => <<"test">>},
    Source = spawn(fun Loop() -> receive {'$gen_call',From,describe} ->
        gen_server:reply(From,maps:without([id],offer(D))),Loop() end end),
    Session = spawn(fun Loop() -> receive {'$gen_call',_,{open,P,_}} -> Parent ! {opened,P},Loop() end end),
    Sup = spawn(fun Loop() -> receive {'$gen_call',From,{start_child,_}} ->
        gen_server:reply(From,{ok,Session}),Loop() end end),
    true = register(parvi_audio_sup,Sup),
    ets:insert(parvi_cluster_trust,{policy,#{<<"cluster">> => <<"cluster">>,
        <<"members">> => #{<<"member">> => #{<<"node">> => atom_to_binary(node(Source))}}}}),
    ets:insert(parvi_clock,{clock,clock(erlang:monotonic_time(nanosecond))}),
    I = parvi_audio_subscription_intent:new(<<"cluster">>,atom_to_binary(node(Source)),offer(D),channel),
    S = #{intent => I,suspended => false,resume_after => undefined,handler => parvi_audio_stream_handler_legacy,
        retry_at => erlang:monotonic_time(millisecond),offers => #{},requests => gen_server:reqids_new(),
        receive_state => #{session => undefined}},
    try Fun(S,Source,D)
    after
        exit(Source,kill),exit(Session,kill),exit(Sup,kill),
        ets:delete(parvi_cluster_trust),ets:delete(parvi_clock)
    end.
