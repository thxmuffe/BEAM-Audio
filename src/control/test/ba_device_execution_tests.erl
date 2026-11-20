-module(ba_device_execution_tests).
-include_lib("eunit/include/eunit.hrl").

execution_gates_test() ->
    Env=[{K,os:getenv(K)} || K <- ["BA_STATE_DIR","BA_IDENTITY_SEED"]],
    Dir=filename:join("/tmp","ba-gates-"++integer_to_list(erlang:unique_integer([positive]))),
    ok=file:make_dir(Dir),os:putenv("BA_STATE_DIR",Dir),os:putenv("BA_IDENTITY_SEED",lists:duplicate(64,$C)),
    {ok,PG}=pg:start_link(ba_permission_pg),unlink(PG),
    {ok,Config}=ba_device_config:start_link(),unlink(Config),
    try
        ?assertNot(ba_device_permission:allowed(record)),
        ?assertNot(ba_device_permission:allowed(broadcast)),
        ?assertNot(ba_device_permission:allowed(unknown)),
        ?assertError(badarg,ets:insert(ba_device_config,{permissions,#{speaker => true}})),
        ok=ba_device_config:change(#{speaker => true,microphone => true,calibrate_microphone => true,calibrate_speaker => true},#{}),
        ?assert(ba_device_permission:allowed(playback)),
        ?assert(ba_device_permission:allowed(record)),
        ?assert(ba_device_permission:allowed(calibrate_microphone)),
        ?assertNot(ba_device_permission:allowed(dsp)),
        ok=ba_device_config:change(#{speaker => false,microphone => false},#{}),
        ?assert(ba_device_permission:allowed(calibrate_microphone)),
        ok=gen_server:stop(Config),
        ?assertNot(ba_device_permission:allowed(calibrate_microphone))
    after
        case is_process_alive(Config) of true -> gen_server:stop(Config);false -> ok end,
        gen_server:stop(PG),file:del_dir_r(Dir),
        [case V of false -> os:unsetenv(K);_ -> os:putenv(K,V) end || {K,V} <- Env]
    end.
