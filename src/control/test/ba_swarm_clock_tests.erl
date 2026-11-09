-module(ba_swarm_clock_tests).
-include_lib("eunit/include/eunit.hrl").

production_cadence_and_single_root_anchor_test() ->
    with_clock(authority,fun(_) ->
        await(fun() -> maps:get(state,ba_swarm_clock:status())=:=synchronized end),
        D = ba_swarm_clock:status(),
        ?assertEqual(5000,maps:get(sample_interval_ms,D)),?assertEqual(30000,maps:get(interval_ms,D)),
        ?assertEqual(20,maps:get(filter_required_samples,D)),?assertEqual(1,maps:get(filter_sample_count,D)),
        ?assertEqual(1,maps:get(upstream_acquisitions,D)),
        {ok,A} = ba_swarm_clock:now(),{ok,B} = ba_swarm_clock:now(),?assert(B>=A),
        ?assertEqual({error,use_authenticated_swarm_control},ba_swarm_clock:reference_sample()),
        ?assertEqual({error,invalid_reference},ba_swarm_clock:set_reference({node,old_trusted_node}))
    end).

offset_compare_and_set_and_restart_test() ->
    with_clock(authority,fun(_) ->
        await(fun() -> maps:get(state,ba_swarm_clock:status())=:=synchronized end),
        Timeline = ba_swarm_clock:id(),
        ?assertEqual(ok,ba_swarm_clock:set_offset(250,1)),
        ?assertEqual({error,conflict},ba_swarm_clock:set_offset(500,1)),
        ?assertEqual({ok,250},ba_swarm_clock:offset()),
        ?assertMatch({ok,#{offset_revision := 2,offset_ms := 250,times := []}},ba_swarm_clock:presentation([])),
        ?assertEqual({error,invalid_request},ba_swarm_clock:set_offset(0)),
        ok = gen_server:stop(ba_swarm_clock),{ok,_} = ba_swarm_clock:start_link(),
        ?assertEqual({error,clock_unavailable},ba_swarm_clock:now()),
        await(fun() -> maps:get(state,ba_swarm_clock:status())=:=synchronized end),
        ?assert(Timeline=/=ba_swarm_clock:id()),?assertEqual({ok,250},ba_swarm_clock:offset()),
        ?assertEqual(2,maps:get(revision,ba_swarm_clock:offset_status()))
    end).

returning_member_does_not_promote_itself_or_trust_cached_offset_test() ->
    with_clock(member,fun({Swarm,Authority}) ->
        ok = gen_server:stop(ba_swarm_clock),
        ok = ba_device_store:save(swarm_time_cache,#{swarm => Swarm,authority => Authority,
            policy => #{<<"revision">> => 7,<<"offset_ms">> => 250}}),
        {ok,_} = ba_swarm_clock:start_link(),
        await(fun() -> maps:get(role,ba_swarm_clock:status())=:=follower end),
        ?assertEqual({error,offset_unavailable},ba_swarm_clock:offset()),
        ?assertMatch(#{revision := 7,offset_ms := 250,ready := false},ba_swarm_clock:offset_status()),
        ?assertEqual({error,authority_reference_only},ba_swarm_clock:set_reference(system)),
        ?assertEqual({error,clock_unavailable},ba_swarm_clock:now()),
        ?assertEqual(0,maps:get(upstream_acquisitions,ba_swarm_clock:status()))
    end).

stale_mapping_and_expired_session_fail_without_timer_cleanup_test() ->
    ets:new(ba_swarm_clock,[named_table,protected]),
    try
        T = erlang:monotonic_time(nanosecond),Ms = erlang:monotonic_time(millisecond),
        D = #{role => follower,mapping => ba_swarm_clock_mapping:new(T,1000000000000000000),
            timeline => <<"timeline">>,confirmed => true,authorization_until => Ms+1000,
            sample_authorization_until => Ms-1,last_sync => T,filter_ready => true,sample_interval_ms => 5000,
            offset => #{<<"revision">> => 1,<<"offset_ms">> => 250},offset_until => Ms+1000},
        ets:insert(ba_swarm_clock,{clock,D}),?assertEqual({error,clock_unavailable},ba_swarm_clock:now()),
        ets:insert(ba_swarm_clock,{clock,D#{sample_authorization_until := Ms+1000,last_sync := T-11000000000}}),
        ?assertEqual({error,clock_unavailable},ba_swarm_clock:now()),
        ets:insert(ba_swarm_clock,{clock,D#{authorization_until := Ms-1}}),
        ?assertEqual({error,offset_unavailable},ba_swarm_clock:offset()),
        ?assertEqual({error,clock_or_offset_unavailable},ba_swarm_clock:presentation([T]))
    after ets:delete(ba_swarm_clock) end.

with_clock(Role,Fun) ->
    {ok,_} = application:ensure_all_started(crypto),
    Seed = crypto:strong_rand_bytes(32),{Pub,_} = crypto:generate_key(eddsa,ed25519,Seed),
    Self = binary:encode_hex(Pub),{Other,_} = crypto:generate_key(eddsa,ed25519),
    Authority = case Role of authority -> Self;member -> binary:encode_hex(Other) end,
    Swarm = binary:encode_hex(crypto:strong_rand_bytes(16)),
    View = #{policy => #{swarm => Swarm,authority => Authority,peers => #{}},until => infinity,local_permissions => []},
    Member = spawn(fun Loop() -> receive {'$gen_call',From,current} -> gen_server:reply(From,{ok,View}),Loop() end end),
    true = register(ba_swarm_membership,Member),
    Dir = filename:join("/tmp","ba_core-time-"++integer_to_list(erlang:unique_integer([positive]))),
    Env = [{K,os:getenv(K)} || K <- ["BA_STATE_DIR","BA_IDENTITY_SEED"]],
    Keys = [clock_reference,clock_sample_interval_ms,clock_filter_samples,clock_interval_ms,clock_slew_ppm],
    AppEnv = [{K,application:get_env(ba_core,K)} || K <- Keys],
    try
        os:putenv("BA_STATE_DIR",Dir),os:putenv("BA_IDENTITY_SEED",binary_to_list(binary:encode_hex(Seed))),
        [application:unset_env(ba_core,K) || K <- Keys],application:set_env(ba_core,clock_reference,system),
        {ok,_} = ba_swarm_clock:start_link(),Fun({Swarm,Authority})
    after
        case whereis(ba_swarm_clock) of undefined -> ok;P -> gen_server:stop(P) end,
        unregister(ba_swarm_membership),exit(Member,kill),
        [case V of false -> os:unsetenv(K);_ -> os:putenv(K,V) end || {K,V} <- Env],
        [case V of undefined -> application:unset_env(ba_core,K);{ok,X} -> application:set_env(ba_core,K,X) end || {K,V} <- AppEnv],
        [file:delete(filename:join(Dir,F)) || F <- ["swarm_time_policy.term","swarm_time_cache.term"]],file:del_dir(Dir)
    end.
await(F) -> await(F,100).
await(_,0) -> error(clock_not_ready);
await(F,N) -> case F() of true -> ok;false -> receive after 10 -> await(F,N-1) end end.

source_packets_use_one_current_clock_and_offset_snapshot_test() ->
    ets:new(ba_swarm_clock,[named_table,protected]),Parent = self(),
    Source = spawn(fun Loop() -> receive {'$gen_call',From,{push,channel,H,_}} ->
        Parent ! {capture_target,maps:get(playback_time,H)},gen_server:reply(From,{ok,[]}),Loop() end end),
    try
        T = erlang:monotonic_time(nanosecond),UTC = erlang:system_time(nanosecond),
        M = ba_swarm_clock_mapping:new(T,UTC-T),
        D = #{role => master,mapping => M,timeline => <<"capture-reference">>,confirmed => true,
            authorization_until => infinity,last_sync => T,filter_ready => true,sample_interval_ms => 5000,
            offset => #{<<"revision">> => 1,<<"offset_ms">> => 1000},offset_until => infinity},
        ets:insert(ba_swarm_clock,{clock,D}),
        Descriptor = #{clock => <<"capture-reference">>,encoding => pcm,sample_format => pcm16_le,sample_rate => 48000,channel_count => 1},
        Input = (ba_audio_input:new())#{descriptor => Descriptor,handler => ba_stream_handler_pcm,source => Source},
        _ = ba_audio_input:captured(<<0:16/little-signed>>,T,Input),
        receive {capture_target,Target} -> ?assertEqual(UTC+1000000000,Target) after 1000 -> error(no_first_target) end,
        ets:insert(ba_swarm_clock,{clock,D#{offset := #{<<"revision">> => 2,<<"offset_ms">> => 250}}}),
        _ = ba_audio_input:captured(<<0:16/little-signed>>,T+1000,Input),
        receive {capture_target,Second} -> ?assertEqual(UTC+1000+250000000,Second) after 1000 -> error(no_new_offset_target) end,
        ets:insert(ba_swarm_clock,{clock,D#{offset_until := undefined}}),
        _ = ba_audio_input:captured(<<0:16/little-signed>>,T+2000,Input),
        receive {capture_target,_} -> error(stale_policy_used_for_capture) after 0 -> ok end
    after exit(Source,kill),ets:delete(ba_swarm_clock) end.

explicit_resync_invalidates_readiness_until_a_fresh_anchor_test() ->
    with_clock(authority,fun(_) ->
        await(fun() -> maps:get(state,ba_swarm_clock:status())=:=synchronized end),
        Revision = maps:get(reference_revision,ba_swarm_clock:status()),Id = ba_swarm_clock:id(),
        ok = ba_swarm_clock:resync(),?assertEqual({error,clock_unavailable},ba_swarm_clock:now()),
        await(fun() -> maps:get(state,ba_swarm_clock:status())=:=synchronized end),
        ?assertEqual(Id,ba_swarm_clock:id()),?assert(maps:get(reference_revision,ba_swarm_clock:status())>Revision)
    end).

session_renewal_retains_filter_but_invalidates_readiness_test() ->
    with_clock(member,fun({_,Authority}) ->
        await(fun() -> maps:get(role,ba_swarm_clock:status())=:=follower end),
        %% Run in the owner of the protected reader table; no live network needed.
        sys:replace_state(ba_swarm_clock,fun(S) ->
            Filter = lists:foldl(fun(N,F) -> ba_swarm_clock_filter:add(#{offset_ns => N,rtt_ns => 1},F) end,
                ba_swarm_clock_filter:new(20),lists:seq(1,20)),
            D = maps:get(clock,S),
            Ready = S#{filter := Filter,filter_reference := reference,
                clock := D#{confirmed := true,filter_ready := true,filter_sample_count := 20}},
            {noreply,Next} = ba_swarm_clock:handle_info({time_session_down,Authority,old_session},Ready),
            ?assertEqual(Filter,maps:get(filter,Next)),
            ?assertEqual(reference,maps:get(filter_reference,Next)),
            ?assertEqual(20,maps:get(filter_sample_count,maps:get(clock,Next))),
            ?assertEqual(false,maps:get(confirmed,maps:get(clock,Next))),Next
        end),
        ?assertEqual({error,clock_unavailable},ba_swarm_clock:now())
    end).
