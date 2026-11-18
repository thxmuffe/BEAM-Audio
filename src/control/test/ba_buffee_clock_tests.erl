-module(ba_buffee_clock_tests).
-include_lib("eunit/include/eunit.hrl").

production_cadence_and_single_root_anchor_test() ->
    with_clock(authority,fun(_) ->
        await(fun() -> maps:get(state,ba_buffee_clock:status())=:=synchronized end),
        D = ba_buffee_clock:status(),
        ?assertEqual(5000,maps:get(sample_interval_ms,D)),?assertEqual(30000,maps:get(interval_ms,D)),
        ?assertEqual(20,maps:get(filter_required_samples,D)),?assertEqual(1,maps:get(filter_sample_count,D)),
        ?assertEqual(1,maps:get(upstream_acquisitions,D)),
        #{utc_time_ns := MasterTime,age_ms := 0,state := fresh}=maps:get(master_clock,D),
        ?assert(is_binary(MasterTime)),?assert(ba_buffee_time_protocol:integer(MasterTime)>0),
        {ok,A} = ba_buffee_clock:now(),{ok,B} = ba_buffee_clock:now(),?assert(B>=A),
        ?assertEqual({error,use_authenticated_buffee_control},ba_buffee_clock:reference_sample()),
        ?assertEqual({error,invalid_reference},ba_buffee_clock:set_reference({node,old_trusted_node}))
    end).

offset_compare_and_set_and_restart_test() ->
    with_clock(authority,fun(_) ->
        await(fun() -> maps:get(state,ba_buffee_clock:status())=:=synchronized end),
        Timeline = ba_buffee_clock:id(),
        ?assertEqual({ok,150},ba_buffee_clock:offset()),
        ?assertEqual(ok,ba_buffee_clock:set_offset(250,1)),
        ?assertEqual({error,conflict},ba_buffee_clock:set_offset(500,1)),
        ?assertEqual({ok,250},ba_buffee_clock:offset()),
        ?assertMatch({ok,#{offset_revision := 2,offset_ms := 250,times := []}},ba_buffee_clock:presentation([])),
        ?assertEqual({error,invalid_request},ba_buffee_clock:set_offset(0)),
        ok = gen_server:stop(ba_buffee_clock),{ok,_} = ba_buffee_clock:start_link(),
        ?assertEqual({error,clock_unavailable},ba_buffee_clock:now()),
        await(fun() -> maps:get(state,ba_buffee_clock:status())=:=synchronized end),
        ?assert(Timeline=/=ba_buffee_clock:id()),?assertEqual({ok,250},ba_buffee_clock:offset()),
        ?assertEqual(2,maps:get(revision,ba_buffee_clock:offset_status()))
    end).

automatic_mode_applies_weighted_requirements_only_while_enabled_test() ->
    with_clock(authority,fun(_) ->
        await(fun() -> maps:get(state,ba_buffee_clock:status())=:=synchronized end),
        ba_buffee_clock:require_offset(600,1),_=sys:get_state(ba_buffee_clock),
        ?assertEqual({ok,150},ba_buffee_clock:offset()),
        ok=ba_buffee_clock:set_automatic(true),
        #{revision := Rev,automatic := true}=ba_buffee_clock:offset_status(),
        ba_buffee_clock:require_offset(600,Rev),_=sys:get_state(ba_buffee_clock),
        ?assertEqual({ok,ba_audio_response_time:increase(150,600)},ba_buffee_clock:offset()),
        %% A window measured under an old local policy is discarded.
        Before=ba_buffee_clock:offset_status(),
        ba_buffee_clock:require_offset(2000,Rev),_=sys:get_state(ba_buffee_clock),
        ?assertEqual(Before,ba_buffee_clock:offset_status()),
        ok=ba_buffee_clock:set_offset(800),
        ?assertMatch(#{automatic := false,offset_ms := 800},ba_buffee_clock:offset_status()),
        ok=gen_server:stop(ba_buffee_clock),{ok,_}=ba_buffee_clock:start_link(),
        await(fun() -> maps:get(state,ba_buffee_clock:status())=:=synchronized end),
        ?assertMatch(#{automatic := false,offset_ms := 800},ba_buffee_clock:offset_status())
    end).

returning_member_does_not_promote_itself_or_trust_cached_offset_test() ->
    with_clock(member,fun({Buffee,Authority}) ->
        ok = gen_server:stop(ba_buffee_clock),
        ok = ba_device_store:save(buffee_time_cache,#{buffee => Buffee,authority => Authority,
            policy => #{<<"revision">> => 7,<<"offset_ms">> => 250}}),
        {ok,_} = ba_buffee_clock:start_link(),
        await(fun() -> maps:get(role,ba_buffee_clock:status())=:=follower end),
        ?assertEqual({error,offset_unavailable},ba_buffee_clock:offset()),
        ?assertMatch(#{revision := 7,offset_ms := 250,ready := false},ba_buffee_clock:offset_status()),
        ?assertEqual({error,authority_reference_only},ba_buffee_clock:set_reference(system)),
        ?assertEqual({error,clock_unavailable},ba_buffee_clock:now()),
        ?assertEqual(0,maps:get(upstream_acquisitions,ba_buffee_clock:status()))
    end).

stale_mapping_and_expired_session_fail_without_timer_cleanup_test() ->
    ets:new(ba_buffee_clock,[named_table,protected]),
    try
        T = erlang:monotonic_time(nanosecond),Ms = erlang:monotonic_time(millisecond),
        D = #{role => follower,mapping => ba_buffee_clock_mapping:new(T,1000000000000000000),
            timeline => <<"timeline">>,confirmed => true,authorization_until => Ms+1000,
            sample_authorization_until => Ms-1,last_sync => T,filter_ready => true,sample_interval_ms => 5000,
            offset => #{<<"revision">> => 1,<<"offset_ms">> => 250},offset_until => Ms+1000},
        ets:insert(ba_buffee_clock,{clock,D}),?assertEqual({error,clock_unavailable},ba_buffee_clock:now()),
        ets:insert(ba_buffee_clock,{clock,D#{sample_authorization_until := Ms+1000,last_sync := T-11000000000}}),
        ?assertEqual({error,clock_unavailable},ba_buffee_clock:now()),
        ets:insert(ba_buffee_clock,{clock,D#{authorization_until := Ms-1}}),
        ?assertEqual({error,offset_unavailable},ba_buffee_clock:offset()),
        ?assertEqual({error,clock_or_offset_unavailable},ba_buffee_clock:presentation([T]))
    after ets:delete(ba_buffee_clock) end.

master_reading_is_visible_before_follower_acquisition_and_marks_stale_test() ->
    ets:new(ba_buffee_clock,[named_table,protected]),
    try
        T=erlang:monotonic_time(nanosecond),Until=erlang:monotonic_time(millisecond)+10000,
        Id=binary:copy(<<"A">>,64),UTC=1794941608123456789,
        D=#{role => follower,master => Id,mapping => undefined,confirmed => true,
            authorization_until => Until,sample_authorization_until => Until,sample_interval_ms => 5000,
            master_sample => #{device => Id,utc_time_ns => UTC,received_at_ns => T-500000000}},
        ets:insert(ba_buffee_clock,{clock,D}),
        Status=ba_buffee_clock:status(),?assertEqual(acquiring,maps:get(state,Status)),
        Reading=maps:get(master_clock,Status),
        ?assertEqual(integer_to_binary(UTC),maps:get(utc_time_ns,Reading)),
        ?assertEqual(fresh,maps:get(state,Reading)),?assert(maps:get(age_ms,Reading)>=500),
        ?assertNot(maps:is_key(master_sample,Status)),
        ets:insert(ba_buffee_clock,{clock,D#{sample_authorization_until := Until-20000}}),
        ?assertEqual(stale,maps:get(state,maps:get(master_clock,ba_buffee_clock:status()))),
        ets:insert(ba_buffee_clock,{clock,D#{master := binary:copy(<<"B">>,64)}}),
        ?assertEqual(#{},maps:get(master_clock,ba_buffee_clock:status()))
    after ets:delete(ba_buffee_clock) end.

with_clock(Role,Fun) ->
    {ok,_} = application:ensure_all_started(crypto),
    Seed = crypto:strong_rand_bytes(32),{Pub,_} = crypto:generate_key(eddsa,ed25519,Seed),
    Self = binary:encode_hex(Pub),{Other,_} = crypto:generate_key(eddsa,ed25519),
    Authority = case Role of authority -> Self;member -> binary:encode_hex(Other) end,
    Buffee = binary:encode_hex(crypto:strong_rand_bytes(16)),
    View = #{policy => #{buffee => Buffee,authority => Authority,peers => #{}},until => infinity,local_permissions => [<<"owner">>]},
    Member = spawn(fun Loop() -> receive {'$gen_call',From,current} -> gen_server:reply(From,{ok,View}),Loop() end end),
    true = register(ba_buffee_membership,Member),
    Dir = filename:join("/tmp","ba_core-time-"++integer_to_list(erlang:unique_integer([positive]))),
    Env = [{K,os:getenv(K)} || K <- ["BA_STATE_DIR","BA_IDENTITY_SEED"]],
    Keys = [clock_reference,clock_sample_interval_ms,clock_filter_samples,clock_interval_ms,clock_slew_ppm],
    AppEnv = [{K,application:get_env(ba_core,K)} || K <- Keys],
    try
        os:putenv("BA_STATE_DIR",Dir),os:putenv("BA_IDENTITY_SEED",binary_to_list(binary:encode_hex(Seed))),
        [application:unset_env(ba_core,K) || K <- Keys],application:set_env(ba_core,clock_reference,system),
        {ok,_} = ba_buffee_clock:start_link(),Fun({Buffee,Authority})
    after
        case whereis(ba_buffee_clock) of undefined -> ok;P -> gen_server:stop(P) end,
        unregister(ba_buffee_membership),exit(Member,kill),
        [case V of false -> os:unsetenv(K);_ -> os:putenv(K,V) end || {K,V} <- Env],
        [case V of undefined -> application:unset_env(ba_core,K);{ok,X} -> application:set_env(ba_core,K,X) end || {K,V} <- AppEnv],
        [file:delete(filename:join(Dir,F)) || F <- ["buffee_time_policy.term","buffee_time_cache.term"]],file:del_dir(Dir)
    end.
await(F) -> await(F,100).
await(_,0) -> error(clock_not_ready);
await(F,N) -> case F() of true -> ok;false -> receive after 10 -> await(F,N-1) end end.

source_packets_use_one_current_clock_and_offset_snapshot_test() ->
    ets:new(ba_buffee_clock,[named_table,protected]),Parent = self(),
    Source = spawn(fun Loop() -> receive {'$gen_call',From,{push,channel,H,_}} ->
        Parent ! {capture_target,maps:get(playback_time,H)},gen_server:reply(From,{ok,[]}),Loop() end end),
    try
        T = erlang:monotonic_time(nanosecond),UTC = erlang:system_time(nanosecond),
        M = ba_buffee_clock_mapping:new(T,UTC-T),
        D = #{role => master,mapping => M,timeline => <<"capture-reference">>,confirmed => true,
            authorization_until => infinity,last_sync => T,filter_ready => true,sample_interval_ms => 5000,
            offset => #{<<"revision">> => 1,<<"offset_ms">> => 1000},offset_until => infinity},
        ets:insert(ba_buffee_clock,{clock,D}),
        Descriptor = #{clock => <<"capture-reference">>,encoding => pcm,sample_format => pcm16_le,sample_rate => 48000,channel_count => 1},
        Input = (ba_audio_input:new())#{descriptor => Descriptor,handler => ba_stream_handler_pcm,source => Source},
        _ = ba_audio_input:captured(<<0:16/little-signed>>,T,Input),
        receive {capture_target,Target} -> ?assertEqual(UTC+1000000000,Target) after 1000 -> error(no_first_target) end,
        ets:insert(ba_buffee_clock,{clock,D#{offset := #{<<"revision">> => 2,<<"offset_ms">> => 250}}}),
        _ = ba_audio_input:captured(<<0:16/little-signed>>,T+1000,Input),
        receive {capture_target,Second} -> ?assertEqual(UTC+1000+250000000,Second) after 1000 -> error(no_new_offset_target) end,
        ets:insert(ba_buffee_clock,{clock,D#{offset_until := undefined}}),
        _ = ba_audio_input:captured(<<0:16/little-signed>>,T+2000,Input),
        receive {capture_target,_} -> error(stale_policy_used_for_capture) after 0 -> ok end
    after exit(Source,kill),ets:delete(ba_buffee_clock) end.

master_resync_refreshes_its_host_anchor_without_losing_time_test() ->
    with_clock(authority,fun(_) ->
        await(fun() -> maps:get(state,ba_buffee_clock:status())=:=synchronized end),
        Revision = maps:get(reference_revision,ba_buffee_clock:status()),Id = ba_buffee_clock:id(),
        ok = ba_buffee_clock:resync(),?assertMatch({ok,_},ba_buffee_clock:now()),
        await(fun() -> maps:get(state,ba_buffee_clock:status())=:=synchronized end),
        ?assertEqual(Id,ba_buffee_clock:id()),?assert(maps:get(reference_revision,ba_buffee_clock:status())>Revision)
    end).

external_reference_failure_does_not_remove_the_masters_host_clock_test() ->
    with_clock(authority,fun(_) ->
        await(fun() -> maps:get(state,ba_buffee_clock:status())=:=synchronized end),
        sys:replace_state(ba_buffee_clock,fun(S) ->
            Worker=self(),Ref=make_ref(),
            {noreply,Next}=ba_buffee_clock:handle_info({upstream_result,Worker,{error,timeout}},
                S#{upstream := #{pid => Worker,monitor => Ref}}),Next
        end),
        ?assertMatch({ok,_},ba_buffee_clock:now()),
        ?assertEqual(upstream_unavailable,maps:get(last_error,ba_buffee_clock:status())),
        ?assertMatch(#{state := fresh,utc_time_ns := _},maps:get(master_clock,ba_buffee_clock:status()))
    end).

fresh_raw_mapping_is_usable_while_filter_is_warming_test() ->
    ets:new(ba_buffee_clock,[named_table,protected]),
    try
        T=erlang:monotonic_time(nanosecond),Until=erlang:monotonic_time(millisecond)+10000,
        D=#{role => follower,mapping => ba_buffee_clock_mapping:new(T,1000000000000000000),
            timeline => <<"raw-test">>,confirmed => true,authorization_until => Until,
            sample_authorization_until => Until,last_sync => T,filter_ready => false,filter_sample_count => 1,
            sample_interval_ms => 5000,raw_offset_ns => <<"1000000000000000000">>},
        ets:insert(ba_buffee_clock,{clock,D}),
        ?assertMatch({ok,_},ba_buffee_clock:now()),
        ?assertMatch(#{state := synchronized,filter_ready := false,estimate_quality := provisional},ba_buffee_clock:status())
    after ets:delete(ba_buffee_clock) end.

initial_calibration_keeps_raw_time_visible_but_fences_audio_targets_test() ->
    ets:new(ba_buffee_clock,[named_table,protected]),
    try
        T=erlang:monotonic_time(nanosecond),Ms=erlang:monotonic_time(millisecond),
        D=#{role => follower,mapping => ba_buffee_clock_mapping:new(T,1000000000000000000),
            timeline => <<"initial-test">>,confirmed => true,authorization_until => Ms+10000,
            sample_authorization_until => Ms+10000,last_sync => T,sample_interval_ms => 5000,
            initial_sync_complete => false,offset => #{<<"revision">> => 1,<<"offset_ms">> => 150},
            offset_until => Ms+10000},
        ets:insert(ba_buffee_clock,{clock,D}),
        {ok,UTC}=ba_buffee_clock:now(),
        ?assertEqual({error,clock_unavailable},ba_buffee_clock:to_monotonic(UTC)),
        ?assertEqual({error,clock_or_offset_unavailable},ba_buffee_clock:presentation([T])),
        ets:insert(ba_buffee_clock,{clock,D#{initial_sync_complete := true}}),
        ?assertEqual({ok,T},ba_buffee_clock:to_monotonic(T+1000000000000000000)),
        ?assertMatch({ok,#{times := [_]}},ba_buffee_clock:presentation([T]))
    after ets:delete(ba_buffee_clock) end.

initial_calibration_commits_without_a_minutes_long_slew_test() ->
    with_clock(member,fun(_) ->
        await(fun() -> maps:get(role,ba_buffee_clock:status())=:=follower end),
        sys:replace_state(ba_buffee_clock,fun(S) ->
            %% Exercise both the five-sample finish and the bounded timeout with
            %% only one valid sample. Neither may slew the provisional 100 ms error.
            lists:foldl(fun({Count,Delay},Current) ->
                T=erlang:monotonic_time(nanosecond),Ms=erlang:monotonic_time(millisecond),
                Offset=1000000000000000000,
                Best=#{offset_ns => Offset,sampled_at => T,round_trip_ns => 1000000},
                D=maps:get(clock,Current),
                Pending=Current#{acquisition := #{count => Count,best => Best,until => Ms+Delay},
                    clock := D#{mapping := ba_buffee_clock_mapping:new(T,Offset+100000000),
                        initial_sync_complete => false,initial_sync_samples => Count}},
                {noreply,Finished}=ba_buffee_clock:handle_info(tick,Pending),
                FD=maps:get(clock,Finished),M=maps:get(mapping,FD),
                ?assertEqual(true,maps:get(initial_sync_complete,FD)),
                ?assertEqual(Offset,ba_buffee_clock_mapping:offset(M,T)),
                ?assertEqual(0,ba_buffee_clock_mapping:remaining(M,T)),
                ?assertEqual(undefined,maps:get(acquisition,Finished)),Finished
            end,S,[{5,2000},{1,-1}])
        end)
    end).

session_renewal_retains_filter_but_invalidates_readiness_test() ->
    with_clock(member,fun({_,Authority}) ->
        await(fun() -> maps:get(role,ba_buffee_clock:status())=:=follower end),
        %% Run in the owner of the protected reader table; no live network needed.
        sys:replace_state(ba_buffee_clock,fun(S) ->
            Filter = lists:foldl(fun(N,F) -> ba_buffee_clock_filter:add(#{offset_ns => N,rtt_ns => 1},F) end,
                ba_buffee_clock_filter:new(20),lists:seq(1,20)),
            D = maps:get(clock,S),
            Ready = S#{filter := Filter,filter_reference := reference,
                clock := D#{confirmed := true,filter_ready := true,filter_sample_count := 20}},
            {noreply,Next} = ba_buffee_clock:handle_info({time_session_down,Authority,old_session},Ready),
            ?assertEqual(Filter,maps:get(filter,Next)),
            ?assertEqual(reference,maps:get(filter_reference,Next)),
            ?assertEqual(20,maps:get(filter_sample_count,maps:get(clock,Next))),
            ?assertEqual(false,maps:get(confirmed,maps:get(clock,Next))),Next
        end),
        ?assertEqual({error,clock_unavailable},ba_buffee_clock:now())
    end).

member_resync_identifies_why_the_filter_was_cleared_test() ->
    with_clock(member,fun(_) ->
        await(fun() -> maps:get(role,ba_buffee_clock:status())=:=follower end),
        sys:replace_state(ba_buffee_clock,fun(S) ->
            D=maps:get(clock,S),Count=maps:get(filter_reset_count,D),
            {reply,ok,Network}=ba_buffee_clock:handle_call({resync,network_changed},undefined,S),
            ND=maps:get(clock,Network),
            ?assertEqual(network_changed,maps:get(filter_reset_reason,ND)),
            ?assertEqual(Count+1,maps:get(filter_reset_count,ND)),
            ?assertEqual(false,maps:get(filter_ready,ND)),
            ?assertEqual(maps:get(mapping,D),maps:get(mapping,ND)),
            {reply,ok,Resume}=ba_buffee_clock:handle_call({resync,resume},undefined,Network),
            ?assertEqual(resume,maps:get(filter_reset_reason,maps:get(clock,Resume))),Resume
        end)
    end).

settings_permission_is_independent_of_clock_hosting_test() ->
    with_clock(authority,fun(_) ->
        await(fun() -> maps:get(state,ba_buffee_clock:status())=:=synchronized end),
        sys:replace_state(ba_buffee_clock,fun(S) -> S#{view := (maps:get(view,S))#{local_permissions => [<<"offset_write">>]}} end),
        ?assertEqual({error,forbidden},ba_buffee_clock:set_offset(500)),
        sys:replace_state(ba_buffee_clock,fun(S) -> S#{view := (maps:get(view,S))#{local_permissions => [<<"stream_publish">>]}} end),
        ?assertEqual(ok,ba_buffee_clock:set_offset(500))
    end).
