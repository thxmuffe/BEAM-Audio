%% First consent increment: one Device ceiling, independent Session broadcasts.
-module(ba_device_consent_tests).
-include_lib("eunit/include/eunit.hrl").

%% A new Device starts in tight; presets write real settings; advanced only reveals them.
presets_test() ->
    Env=[{K,os:getenv(K)} || K <- ["BA_STATE_DIR","BA_IDENTITY_SEED"]],
    Old=[{K,application:get_env(ba_core,K)} || K <- [restore_session_on_start,device_default_preset]],
    Dir=filename:join("/tmp","ba-presets-"++integer_to_list(erlang:unique_integer([positive]))),
    ok=file:make_dir(Dir),os:putenv("BA_STATE_DIR",Dir),os:putenv("BA_IDENTITY_SEED",lists:duplicate(64,$C)),
    application:set_env(ba_core,restore_session_on_start,false),
    application:unset_env(ba_core,device_default_preset),
    {ok,Sup}=ba_sup:start_link(),unlink(Sup),
    try
        Snap=fun() -> ba_device_config:snapshot() end,Pol=fun(K) -> maps:get(K,maps:get(policies,Snap())) end,
        ?assertEqual(tight,maps:get(preset,Snap())),
        ?assertEqual(no,Pol(moderator_requests)),?assertEqual(no,Pol(microphone)),?assertEqual(no,Pol(location)),
        ?assertEqual(no,Pol(inspect)),?assertEqual(no,Pol(dsp)),
        ?assertEqual(ask,Pol(on_air_requests)),?assertEqual(ask,Pol(speaker)),?assertEqual(ask,Pol(calibrate_speaker)),
        ?assertNot(maps:get(auto_accept,Snap())),?assertNot(maps:get(auto_grant,Snap())),
        ok=ba_device_config:preset(friendly,#{}),
        ?assertEqual(friendly,maps:get(preset,Snap())),?assert(maps:get(auto_grant,Snap())),?assertNot(maps:get(auto_accept,Snap())),
        ?assertEqual(always,Pol(speaker)),?assertEqual(always,Pol(calibrate_microphone)),?assertEqual(always,Pol(location)),?assertEqual(ask,Pol(microphone)),
        ?assertEqual(always,Pol(inspect)),?assertEqual(always,Pol(dsp)),
        ?assert(ba_device_permission:allowed(playback)),?assertNot(ba_device_permission:allowed(record)),
        ok=ba_device_config:preset(no_control,#{}),
        ?assert(maps:get(auto_accept,Snap())),?assert(maps:get(auto_grant,Snap())),?assertEqual(always,ba_device_config:policy(on_air_requests)),
        %% Choices are hidden, not changed, by no_control.
        ?assertEqual(always,Pol(speaker)),
        ok=ba_device_config:preset(tight,#{}),
        ?assertNot(ba_device_permission:allowed(playback)),?assertEqual(no,Pol(moderator_requests)),
        %% advanced reveals and changes nothing; touching a setting by hand keeps it advanced.
        ok=ba_device_config:preset(advanced,#{}),?assertEqual(advanced,maps:get(preset,Snap())),?assertEqual(no,Pol(moderator_requests)),
        ok=ba_device_config:preset(friendly,#{}),ok=ba_device_config:policy(microphone,always,#{}),
        ?assertEqual(advanced,maps:get(preset,Snap())),
        %% A preset that stops one grant and gives another still applies.
        ok=ba_device_config:preset(tight,#{}),ok=ba_device_config:policy(microphone,always,#{}),
        ok=ba_device_config:preset(friendly,#{expected_revision => maps:get(revision,Snap()),request_id => <<"mixed">>}),
        ?assertEqual(friendly,maps:get(preset,Snap())),?assertEqual(ask,Pol(microphone)),?assertEqual(always,Pol(speaker)),
        ?assertEqual({error,invalid_configuration},ba_device_config:preset(nope,#{})),
        %% It survives a restart.
        ok=ba_device_config:preset(friendly,#{}),Running=whereis(ba_device_config),ok=gen_server:stop(Running,shutdown,5000),
        (fun Wait(0) -> error(not_restarted);Wait(N) -> case whereis(ba_device_config) of P when is_pid(P),P=/=Running -> ok;_ -> receive after 10 -> Wait(N-1) end end end)(100),
        ?assertEqual(friendly,maps:get(preset,Snap())),?assert(maps:get(auto_grant,Snap()))
    after
        gen_server:stop(Sup,shutdown,5000),file:del_dir_r(Dir),
        [case V of false -> os:unsetenv(K);_ -> os:putenv(K,V) end || {K,V} <- Env],
        [case V of undefined -> application:unset_env(ba_core,K);{ok,X} -> application:set_env(ba_core,K,X) end || {K,V} <- Old]
    end.

device_wide_consent_test() ->
    Env=[{K,os:getenv(K)} || K <- ["BA_STATE_DIR","BA_IDENTITY_SEED"]],
    Keys=[restore_session_on_start,device_default_preset],
    Old=[{K,application:get_env(ba_core,K)} || K <- Keys],
    Dir=filename:join("/tmp","ba-consent-"++integer_to_list(erlang:unique_integer([positive]))),
    ok=file:make_dir(Dir),os:putenv("BA_STATE_DIR",Dir),os:putenv("BA_IDENTITY_SEED",lists:duplicate(64,$B)),
    application:set_env(ba_core,restore_session_on_start,false),
    %% These tests start from the plain defaults; the presets have their own test below.
    application:set_env(ba_core,device_default_preset,advanced),
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
        %% The root restarts its single permission owner; the Device returns to the state it was in.
        wait_config(Default,50),
        ?assert(maps:get(speaker,ba_device_config:consent())),?assert(maps:get(calibrate_speaker,ba_device_config:consent())),
        ?assertNot(maps:get(microphone,ba_device_config:consent())),
        ?assertEqual({error,nothing_to_redo},ba_device_config:redo(#{})),
        ok=ba_device_config:change(#{speaker => false,calibrate_speaker => false},#{}),
        %% Policies: ask is the default, always is the grant, no is remembered.
        Policies=fun() -> maps:get(policies,ba_device_config:snapshot()) end,
        ?assertEqual(always,maps:get(inspect,Policies())),
        ?assert(lists:all(fun(V) -> V=:=ask end,maps:values(maps:remove(inspect,Policies())))),
        ok=ba_device_config:policy(microphone,always,#{}),
        ?assert(maps:get(microphone,ba_device_config:consent())),?assertEqual(always,maps:get(microphone,Policies())),
        ok=ba_device_config:policy(microphone,no,#{}),
        ?assertNot(maps:get(microphone,ba_device_config:consent())),?assertEqual(no,maps:get(microphone,Policies())),
        ok=ba_device_config:policy(microphone,ask,#{}),
        ?assertNot(maps:get(microphone,ba_device_config:consent())),?assertEqual(ask,maps:get(microphone,Policies())),
        ok=ba_device_config:policy(calibrate_microphone,always,#{}),
        ?assert(ba_device_permission:allowed(calibrate_microphone)),?assertNot(ba_device_permission:allowed(calibrate_speaker)),
        %% The one Calibration control changes both resources in one edit.
        CalibrationRevision=maps:get(revision,ba_device_config:snapshot()),
        ok=ba_device_config:policy(calibration,always,#{expected_revision => CalibrationRevision}),
        ?assertEqual(CalibrationRevision+1,maps:get(revision,ba_device_config:snapshot())),
        ?assert(ba_device_permission:allowed(calibrate_microphone)),?assert(ba_device_permission:allowed(calibrate_speaker)),
        ok=ba_device_config:policy(calibration,no,#{}),
        ?assertEqual(no,maps:get(calibrate_microphone,Policies())),?assertEqual(no,maps:get(calibrate_speaker,Policies())),
        ?assertNot(ba_device_permission:allowed(calibrate_microphone)),?assertNot(ba_device_permission:allowed(calibrate_speaker)),
        ok=ba_device_config:policy(calibration,ask,#{}),
        ?assertEqual(ask,maps:get(calibrate_microphone,Policies())),?assertEqual(ask,maps:get(calibrate_speaker,Policies())),
        %% Answering other Devices' on-air requests grants this Device nothing.
        ok=ba_device_config:policy(on_air_requests,always,#{}),?assertEqual(always,ba_device_config:policy(on_air_requests)),
        ?assertNot(maps:is_key(on_air_requests,ba_device_config:consent())),
        ok=ba_device_config:policy(on_air_requests,ask,#{}),?assertEqual(ask,ba_device_config:policy(on_air_requests)),
        ?assertEqual({error,invalid_configuration},ba_device_config:policy(broadcast,always,#{})),
        ?assertEqual({error,invalid_configuration},ba_device_config:policy(microphone,sometimes,#{})),
        %% The top switch grants everything and leaves each stored choice alone.
        ok=ba_device_config:policy(microphone,no,#{}),ok=ba_device_config:policy(calibrate_microphone,ask,#{}),
        ok=ba_device_config:policy(speaker,always,#{}),Before=Policies(),
        ok=ba_device_config:auto_accept(true,#{}),
        ?assert(maps:get(auto_accept,ba_device_config:snapshot())),?assertEqual(Before,Policies()),
        ?assert(ba_device_permission:allowed(record)),?assert(ba_device_permission:allowed(calibrate_speaker)),
        %% Requests for rights have their own switch.
        ?assertEqual(ask,ba_device_config:policy(on_air_requests)),
        ok=ba_device_config:policy(speaker,no,#{}),?assert(ba_device_permission:allowed(playback)),
        ok=ba_device_config:auto_accept(false,#{}),
        ?assertNot(maps:get(auto_accept,ba_device_config:snapshot())),
        ?assertEqual(Before#{speaker := no},Policies()),
        ?assertNot(ba_device_permission:allowed(record)),?assertNot(ba_device_permission:allowed(playback)),
        ?assertEqual(ask,ba_device_config:policy(on_air_requests)),
        %% Location is a recorded choice; it never becomes a consent flag.
        ok=ba_device_config:policy(location,always,#{}),?assertEqual(always,ba_device_config:policy(location)),
        ?assertNot(maps:is_key(location,ba_device_config:consent())),
        %% Auto grant answers every request for a right and leaves the choices under it alone.
        ok=ba_device_config:policy(moderator_requests,no,#{}),Grants=Policies(),
        ok=ba_device_config:auto_grant(true,#{}),
        ?assert(maps:get(auto_grant,ba_device_config:snapshot())),?assertEqual(Grants,Policies()),
        ?assertEqual(always,ba_device_config:policy(on_air_requests)),?assertEqual(always,ba_device_config:policy(moderator_requests)),
        ?assertNot(ba_device_permission:allowed(record)),
        ok=ba_device_config:auto_grant(false,#{}),
        ?assertEqual(no,ba_device_config:policy(moderator_requests)),?assertEqual(ask,ba_device_config:policy(on_air_requests)),
        %% Every setting survives a restart: choices, both switches, grants and ON AIR.
        ok=ba_device_config:policy(microphone,always,#{}),ok=ba_device_config:auto_grant(true,#{}),
        ok=ba_device_config:policy(location,no,#{}),ok=ba_device_config:change(#{broadcast => true},#{}),
        Before2=Policies(),Consent2=ba_device_config:consent(),Running=whereis(ba_device_config),
        ok=gen_server:stop(Running,shutdown,5000),wait_config(Running,50),
        ?assertEqual(Before2,Policies()),?assert(maps:get(auto_grant,ba_device_config:snapshot())),
        ?assertNot(maps:get(auto_accept,ba_device_config:snapshot())),
        ?assertEqual(always,ba_device_config:policy(moderator_requests)),
        ?assertEqual(Consent2,ba_device_config:consent()),?assert(maps:get(broadcast,ba_device_config:consent())),
        ok=ba_device_config:auto_accept(true,#{}),Consent3=ba_device_config:consent(),
        Running2=whereis(ba_device_config),ok=gen_server:stop(Running2,shutdown,5000),wait_config(Running2,50),
        ?assert(maps:get(auto_accept,ba_device_config:snapshot())),?assertEqual(Consent3,ba_device_config:consent()),
        ?assert(maps:get(speaker,ba_device_config:consent()))
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
