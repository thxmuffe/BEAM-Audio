-module(ba_device_execution_tests).
-include_lib("eunit/include/eunit.hrl").

execution_gates_test() ->
    Env=[{K,os:getenv(K)} || K <- ["BA_STATE_DIR","BA_IDENTITY_SEED"]],
    Old=application:get_env(ba_core,runtime_profile),
    Dir=filename:join("/tmp","ba-gates-"++integer_to_list(erlang:unique_integer([positive]))),
    ok=file:make_dir(Dir),os:putenv("BA_STATE_DIR",Dir),os:putenv("BA_IDENTITY_SEED",lists:duplicate(64,$C)),
    application:set_env(ba_core,runtime_profile,buffee_control),
    {ok,PG}=pg:start_link(ba_permission_pg),unlink(PG),
    {ok,Config}=ba_device_config:start_link(),unlink(Config),
    try
        ?assertNot(ba_device_permission:allowed(record)),
        ?assertNot(ba_device_permission:allowed(broadcast)),
        ?assertNot(ba_device_permission:allowed(unknown)),
        ?assertError(badarg,ets:insert(ba_device_config,{permissions,#{speaker => true}})),
        ?assertEqual({error,consent_required},ba_mac_output:open(#{})),
        ?assertEqual({error,consent_required},ba_ios_audio:open(#{})),
        ?assertEqual({error,consent_required},ba_audio_native_engine:open(#{})),
        denied_writes(),
        Input=ba_audio_input:new(),Mac=#{kind => microphone,port => undefined,input => Input},
        IOS=#{kind => microphone,socket => undefined,input => Input},
        ?assertMatch({reply,{error,consent_required},_},ba_mac_audio:handle_call(start,{self(),make_ref()},Mac)),
        ?assertMatch({reply,{error,consent_required},_},ba_ios_input:handle_call(start,{self(),make_ref()},IOS)),
        ?assertEqual({stop,consent_required},ba_device_test_worker:init(#{})),
        ok=ba_device_config:change(#{speaker => true,microphone => true,calibrate => true},#{}),
        ?assert(ba_device_permission:allowed(playback)),
        ?assert(ba_device_permission:allowed(record)),
        ?assert(ba_device_permission:allowed(calibrate)),
        ?assertNot(ba_device_permission:allowed(dsp)),
        ok=ba_device_config:change(#{speaker => false,microphone => false},#{}),
        denied_writes(),
        %% Late queued blocks are discarded before parsing/publishing their data.
        ?assertEqual(stopped,maps:get(state,ba_audio_input:captured(<<1,2,3>>,0,Input#{permission => record}))),
        ?assert(ba_device_permission:allowed(calibrate)),
        ok=gen_server:stop(Config),
        ?assertNot(ba_device_permission:allowed(calibrate)),
        ?assertEqual({error,consent_required},ba_ios_audio:open(#{}))
    after
        case is_process_alive(Config) of true -> gen_server:stop(Config);false -> ok end,
        gen_server:stop(PG),file:del_dir_r(Dir),
        [case V of false -> os:unsetenv(K);_ -> os:putenv(K,V) end || {K,V} <- Env],
        case Old of undefined -> application:unset_env(ba_core,runtime_profile);{ok,V} -> application:set_env(ba_core,runtime_profile,V) end
    end.
denied_writes() ->
    ?assertEqual({error,consent_revoked},ba_mac_output:write(#{},0,1,<<>>)),
    ?assertEqual({error,consent_revoked},ba_ios_audio:write(#{},0,1,<<>>)),
    ?assertEqual({error,consent_revoked},ba_audio_native_engine:command(no_socket,play)),
    ?assertEqual({error,consent_revoked},ba_audio_native_engine:command(no_socket,{presentation,#{}})).
