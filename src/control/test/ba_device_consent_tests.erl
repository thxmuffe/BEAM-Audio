%% First consent increment: one Device ceiling, independent Session broadcasts.
-module(ba_device_consent_tests).
-include_lib("eunit/include/eunit.hrl").

device_wide_consent_test() ->
    Env=[{K,os:getenv(K)} || K <- ["BA_STATE_DIR","BA_IDENTITY_SEED"]],
    Keys=[runtime_profile,audio_consent,restore_buffee_on_start],
    Old=[{K,application:get_env(ba_core,K)} || K <- Keys],
    Dir=filename:join("/tmp","ba-consent-"++integer_to_list(erlang:unique_integer([positive]))),
    ok=file:make_dir(Dir),os:putenv("BA_STATE_DIR",Dir),os:putenv("BA_IDENTITY_SEED",lists:duplicate(64,$B)),
    application:set_env(ba_core,runtime_profile,buffee_control),
    application:set_env(ba_core,restore_buffee_on_start,false),
    application:set_env(ba_core,audio_consent,#{speaker => true,microphone => true,broadcast => true}),
    {ok,Sup}=ba_sup:start_link(),unlink(Sup),
    try
        ?assertNot(maps:get(speaker,ba_app_session:consent())),
        A=maps:get(session_id,ba_sessions:request(#{<<"method">> => <<"new_session">>})),
        B=maps:get(session_id,ba_sessions:request(#{<<"method">> => <<"new_session">>})),
        In=fun(Id,F) -> ba_session_scope:run(Id,F) end,
        Default=whereis(ba_device_config),
        ?assertEqual(Default,In(A,fun() -> ba_session_scope:whereis(ba_device_config) end)),
        ?assertEqual(Default,In(B,fun() -> ba_session_scope:whereis(ba_device_config) end)),
        ok=In(A,fun() -> ba_app_session:capability(microphone,true) end),
        ?assert(maps:get(microphone,In(B,fun ba_app_session:consent/0))),
        ok=In(A,fun() -> ba_app_session:capability(broadcast,true) end),
        ?assert(maps:get(broadcast,In(A,fun ba_app_session:consent/0))),
        ?assertNot(maps:get(broadcast,In(B,fun ba_app_session:consent/0))),
        ok=In(B,fun() -> ba_app_session:capability(microphone,false) end),
        ?assertNot(maps:get(microphone,In(A,fun ba_app_session:consent/0))),
        ?assertEqual({error,local_approval_required},ba_device_config:undo(#{})),
        ?assertNot(maps:get(can_undo,ba_device_config:snapshot())),
        ok=ba_device_config:change(#{speaker => true,calibrate_speaker => true},#{}),
        ba_sessions:request(#{<<"method">> => <<"close_session">>,<<"session">> => A}),
        ?assert(maps:get(speaker,In(B,fun ba_app_session:consent/0))),
        ok=gen_server:stop(Default),
        %% The root restarts its single permission owner with every grant OFF.
        wait_config(Default,50),
        ?assert(lists:all(fun(V) -> V=:=false end,maps:values(ba_device_config:consent()))),
        ?assertEqual({error,nothing_to_redo},ba_device_config:redo(#{})),
        ?assertNot(maps:get(can_undo,ba_device_config:snapshot())),
        %% Policies: ask is the default, always is the grant, no is remembered.
        Policies=fun() -> maps:get(policies,ba_device_config:snapshot()) end,
        ?assert(lists:all(fun(V) -> V=:=ask end,maps:values(Policies()))),
        ok=ba_device_config:policy(microphone,always,#{}),
        ?assert(maps:get(microphone,ba_device_config:consent())),?assertEqual(always,maps:get(microphone,Policies())),
        ok=ba_device_config:policy(microphone,no,#{}),
        ?assertNot(maps:get(microphone,ba_device_config:consent())),?assertEqual(no,maps:get(microphone,Policies())),
        ok=ba_device_config:policy(microphone,ask,#{}),
        ?assertNot(maps:get(microphone,ba_device_config:consent())),?assertEqual(ask,maps:get(microphone,Policies())),
        ok=ba_device_config:policy(calibrate_microphone,always,#{}),
        ?assert(ba_device_permission:allowed(calibrate_microphone)),?assertNot(ba_device_permission:allowed(calibrate_speaker)),
        %% Answering other Devices' on-air requests grants this Device nothing.
        ok=ba_device_config:policy(on_air_requests,always,#{}),?assertEqual(always,ba_device_config:policy(on_air_requests)),
        ?assertNot(maps:is_key(on_air_requests,ba_device_config:consent())),
        ok=ba_device_config:policy(on_air_requests,ask,#{}),?assertEqual(ask,ba_device_config:policy(on_air_requests)),
        ?assertEqual({error,invalid_configuration},ba_device_config:policy(broadcast,always,#{})),
        ?assertEqual({error,invalid_configuration},ba_device_config:policy(microphone,sometimes,#{}))
    after
        gen_server:stop(Sup,shutdown,5000),file:del_dir_r(Dir),
        [case V of false -> os:unsetenv(K);_ -> os:putenv(K,V) end || {K,V} <- Env],
        [case V of undefined -> application:unset_env(ba_core,K);{ok,X} -> application:set_env(ba_core,K,X) end || {K,V} <- Old]
    end.
wait_config(_,0) -> error(config_not_restarted);
wait_config(Old,N) -> case whereis(ba_device_config) of
    P when is_pid(P),P=/=Old -> ok;
    _ -> receive after 10 -> wait_config(Old,N-1) end
end.
