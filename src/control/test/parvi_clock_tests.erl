-module(parvi_clock_tests).
-include_lib("eunit/include/eunit.hrl").

production_cadence_and_single_root_anchor_test() ->
    with_clock(authority,fun(_) ->
        await(fun() -> maps:get(state,parvi_clock:status())=:=synchronized end),
        D = parvi_clock:status(),
        ?assertEqual(5000,maps:get(sample_interval_ms,D)),?assertEqual(30000,maps:get(interval_ms,D)),
        ?assertEqual(20,maps:get(filter_required_samples,D)),?assertEqual(1,maps:get(filter_sample_count,D)),
        ?assertEqual(1,maps:get(upstream_acquisitions,D)),
        {ok,A} = parvi_clock:now(),{ok,B} = parvi_clock:now(),?assert(B>=A),
        ?assertEqual({error,use_authenticated_swarm_control},parvi_clock:reference_sample()),
        ?assertEqual({error,invalid_reference},parvi_clock:set_reference({node,old_trusted_node}))
    end).

offset_compare_and_set_and_restart_test() ->
    with_clock(authority,fun(_) ->
        await(fun() -> maps:get(state,parvi_clock:status())=:=synchronized end),
        Timeline = parvi_clock:id(),
        ?assertEqual(ok,parvi_clock:set_offset(250,1)),
        ?assertEqual({error,conflict},parvi_clock:set_offset(500,1)),
        ?assertEqual({ok,250},parvi_clock:offset()),
        ?assertMatch({ok,#{offset_revision := 2,offset_ms := 250,times := []}},parvi_clock:presentation([])),
        ?assertEqual({error,invalid_request},parvi_clock:set_offset(0)),
        ok = gen_server:stop(parvi_clock),{ok,_} = parvi_clock:start_link(),
        ?assertEqual({error,clock_unavailable},parvi_clock:now()),
        await(fun() -> maps:get(state,parvi_clock:status())=:=synchronized end),
        ?assert(Timeline=/=parvi_clock:id()),?assertEqual({ok,250},parvi_clock:offset()),
        ?assertEqual(2,maps:get(revision,parvi_clock:offset_status()))
    end).

returning_member_does_not_promote_itself_or_trust_cached_offset_test() ->
    with_clock(member,fun({Swarm,Authority}) ->
        ok = gen_server:stop(parvi_clock),
        ok = parvi_cluster_store:save(swarm_time_cache,#{swarm => Swarm,authority => Authority,
            policy => #{<<"revision">> => 7,<<"offset_ms">> => 250}}),
        {ok,_} = parvi_clock:start_link(),
        await(fun() -> maps:get(role,parvi_clock:status())=:=follower end),
        ?assertEqual({error,offset_unavailable},parvi_clock:offset()),
        ?assertMatch(#{revision := 7,offset_ms := 250,ready := false},parvi_clock:offset_status()),
        ?assertEqual({error,authority_reference_only},parvi_clock:set_reference(system)),
        ?assertEqual({error,clock_unavailable},parvi_clock:now()),
        ?assertEqual(0,maps:get(upstream_acquisitions,parvi_clock:status()))
    end).

stale_mapping_and_expired_session_fail_without_timer_cleanup_test() ->
    ets:new(parvi_clock,[named_table,protected]),
    try
        T = erlang:monotonic_time(nanosecond),Ms = erlang:monotonic_time(millisecond),
        D = #{role => follower,mapping => parvi_clock_mapping:new(T,1000000000000000000),
            timeline => <<"timeline">>,confirmed => true,authorization_until => Ms+1000,
            sample_authorization_until => Ms-1,last_sync => T,filter_ready => true,sample_interval_ms => 5000,
            offset => #{<<"revision">> => 1,<<"offset_ms">> => 250},offset_until => Ms+1000},
        ets:insert(parvi_clock,{clock,D}),?assertEqual({error,clock_unavailable},parvi_clock:now()),
        ets:insert(parvi_clock,{clock,D#{sample_authorization_until := Ms+1000,last_sync := T-11000000000}}),
        ?assertEqual({error,clock_unavailable},parvi_clock:now()),
        ets:insert(parvi_clock,{clock,D#{authorization_until := Ms-1}}),
        ?assertEqual({error,offset_unavailable},parvi_clock:offset()),
        ?assertEqual({error,clock_or_offset_unavailable},parvi_clock:presentation([T]))
    after ets:delete(parvi_clock) end.

with_clock(Role,Fun) ->
    {ok,_} = application:ensure_all_started(crypto),
    Seed = crypto:strong_rand_bytes(32),{Pub,_} = crypto:generate_key(eddsa,ed25519,Seed),
    Self = binary:encode_hex(Pub),{Other,_} = crypto:generate_key(eddsa,ed25519),
    Authority = case Role of authority -> Self;member -> binary:encode_hex(Other) end,
    Swarm = binary:encode_hex(crypto:strong_rand_bytes(16)),
    View = #{policy => #{swarm => Swarm,authority => Authority,peers => #{}},until => infinity,local_permissions => []},
    Member = spawn(fun Loop() -> receive {'$gen_call',From,current} -> gen_server:reply(From,{ok,View}),Loop() end end),
    true = register(parvi_swarm_membership,Member),
    Dir = filename:join("/tmp","parvi-time-"++integer_to_list(erlang:unique_integer([positive]))),
    Env = [{K,os:getenv(K)} || K <- ["PARVI_STATE_DIR","PARVI_IDENTITY_SEED"]],
    Keys = [clock_reference,clock_sample_interval_ms,clock_filter_samples,clock_interval_ms,clock_slew_ppm],
    AppEnv = [{K,application:get_env(parvi,K)} || K <- Keys],
    try
        os:putenv("PARVI_STATE_DIR",Dir),os:putenv("PARVI_IDENTITY_SEED",binary_to_list(binary:encode_hex(Seed))),
        [application:unset_env(parvi,K) || K <- Keys],application:set_env(parvi,clock_reference,system),
        {ok,_} = parvi_clock:start_link(),Fun({Swarm,Authority})
    after
        case whereis(parvi_clock) of undefined -> ok;P -> gen_server:stop(P) end,
        unregister(parvi_swarm_membership),exit(Member,kill),
        [case V of false -> os:unsetenv(K);_ -> os:putenv(K,V) end || {K,V} <- Env],
        [case V of undefined -> application:unset_env(parvi,K);{ok,X} -> application:set_env(parvi,K,X) end || {K,V} <- AppEnv],
        [file:delete(filename:join(Dir,F)) || F <- ["swarm_time_policy.term","swarm_time_cache.term"]],file:del_dir(Dir)
    end.
await(F) -> await(F,100).
await(_,0) -> error(clock_not_ready);
await(F,N) -> case F() of true -> ok;false -> receive after 10 -> await(F,N-1) end end.

source_packets_use_one_current_clock_and_offset_snapshot_test() ->
    ets:new(parvi_clock,[named_table,protected]),Parent = self(),
    Source = spawn(fun Loop() -> receive {'$gen_call',From,{push,channel,H,_}} ->
        Parent ! {capture_target,maps:get(playback_time,H)},gen_server:reply(From,{ok,[]}),Loop() end end),
    try
        T = erlang:monotonic_time(nanosecond),UTC = erlang:system_time(nanosecond),
        M = parvi_clock_mapping:new(T,UTC-T),
        D = #{role => master,mapping => M,timeline => <<"capture-reference">>,confirmed => true,
            authorization_until => infinity,last_sync => T,filter_ready => true,sample_interval_ms => 5000,
            offset => #{<<"revision">> => 1,<<"offset_ms">> => 1000},offset_until => infinity},
        ets:insert(parvi_clock,{clock,D}),
        Descriptor = #{clock => <<"capture-reference">>,encoding => pcm,sample_format => pcm16_le,sample_rate => 48000,channel_count => 1},
        Input = (parvi_audio_input:new())#{descriptor => Descriptor,handler => parvi_audio_stream_handler_legacy,source => Source},
        _ = parvi_audio_input:captured(<<0:16/little-signed>>,T,Input),
        receive {capture_target,Target} -> ?assertEqual(UTC+1000000000,Target) after 1000 -> error(no_first_target) end,
        ets:insert(parvi_clock,{clock,D#{offset := #{<<"revision">> => 2,<<"offset_ms">> => 250}}}),
        _ = parvi_audio_input:captured(<<0:16/little-signed>>,T+1000,Input),
        receive {capture_target,Second} -> ?assertEqual(UTC+1000+250000000,Second) after 1000 -> error(no_new_offset_target) end,
        ets:insert(parvi_clock,{clock,D#{offset_until := undefined}}),
        _ = parvi_audio_input:captured(<<0:16/little-signed>>,T+2000,Input),
        receive {capture_target,_} -> error(stale_policy_used_for_capture) after 0 -> ok end
    after exit(Source,kill),ets:delete(parvi_clock) end.

explicit_resync_invalidates_readiness_until_a_fresh_anchor_test() ->
    with_clock(authority,fun(_) ->
        await(fun() -> maps:get(state,parvi_clock:status())=:=synchronized end),
        Revision = maps:get(reference_revision,parvi_clock:status()),Id = parvi_clock:id(),
        ok = parvi_clock:resync(),?assertEqual({error,clock_unavailable},parvi_clock:now()),
        await(fun() -> maps:get(state,parvi_clock:status())=:=synchronized end),
        ?assertEqual(Id,parvi_clock:id()),?assert(maps:get(reference_revision,parvi_clock:status())>Revision)
    end).
