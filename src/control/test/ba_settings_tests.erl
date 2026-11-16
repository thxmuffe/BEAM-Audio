-module(ba_settings_tests).
-include_lib("eunit/include/eunit.hrl").

%% Changes reach the file soon after they happen, as plain text, and come back after a restart.
saved_as_text_and_restored_test() -> fixture(fun(Dir) ->
    ok=ba_settings:put(automation,#{auto_accept => true}),ok=ba_settings:put(name,<<"Living room">>),
    timer:sleep(400),
    {ok,Terms}=file:consult(filename:join(Dir,"settings.config")),
    ?assertEqual(#{auto_accept => true},proplists:get_value(automation,Terms)),
    restart(),
    ?assertEqual(<<"Living room">>,ba_settings:get(name)),
    ?assertEqual(43,ba_settings:update(count,fun(N) -> N+1 end,42))
end).

%% A crash loses at most the last ?DELAY ms; an orderly stop loses nothing.
stop_writes_pending_changes_test() -> fixture(fun(_) ->
    ok=ba_settings:put(on_air,true),gen_server:stop(ba_settings),{ok,_}=ba_settings:start_link(),
    ?assertEqual(true,ba_settings:get(on_air))
end).

%% A file the person broke is kept aside; the Device starts from defaults.
unreadable_file_is_kept_aside_test() -> fixture(fun(Dir) ->
    Path=filename:join(Dir,"settings.config"),
    gen_server:stop(ba_settings),ok=file:write_file(Path,<<"{broken">>),{ok,_}=ba_settings:start_link(),
    ?assertEqual(undefined,ba_settings:get(on_air)),
    ?assert(filelib:is_regular(Path++".broken"))
end).

%% Launch configuration: the file overrides environment and application settings; secrets never come from it.
file_overrides_launch_configuration_test() -> fixture(fun(_) ->
    os:putenv("BA_SETTINGS_TEST","from-env"),application:set_env(ba_core,settings_test,from_app),
    ?assertEqual("from-env",ba_settings:env("BA_SETTINGS_TEST")),?assertEqual(from_app,ba_settings:app(settings_test,none)),
    ok=ba_settings:put(environment,#{"BA_SETTINGS_TEST" => "from-file","BA_IDENTITY_SEED" => "not-a-secret-source"}),
    ok=ba_settings:put(runtime,#{settings_test => from_file}),
    ?assertEqual("from-file",ba_settings:env("BA_SETTINGS_TEST")),?assertEqual(from_file,ba_settings:app(settings_test,none)),
    ?assertEqual(os:getenv("BA_IDENTITY_SEED"),ba_settings:env("BA_IDENTITY_SEED")),
    os:unsetenv("BA_SETTINGS_TEST"),application:unset_env(ba_core,settings_test)
end).

restart() -> gen_server:stop(ba_settings),{ok,_}=ba_settings:start_link(),ok.
fixture(F) ->
    Old=os:getenv("BA_STATE_DIR"),
    Dir=filename:join("/tmp","ba-settings-"++integer_to_list(erlang:unique_integer([positive]))),
    ok=file:make_dir(Dir),os:putenv("BA_STATE_DIR",Dir),{ok,_}=ba_settings:start_link(),
    try F(Dir) after
        try gen_server:stop(ba_settings) catch exit:_ -> ok end,file:del_dir_r(Dir),
        case Old of false -> os:unsetenv("BA_STATE_DIR");_ -> os:putenv("BA_STATE_DIR",Old) end
    end.
