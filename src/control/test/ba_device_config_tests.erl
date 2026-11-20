-module(ba_device_config_tests).
-include_lib("eunit/include/eunit.hrl").

%% Ask raises one request per requester; the user's Allow turns the use on,
%% Decline stops that requester asking until the policy changes; No refuses.
ask_requests_wait_for_this_devices_answer_test() -> fixture(fun(_) ->
    Key=calibrate_speaker,ok=ba_device_config:policy(Key,ask,#{}),
    Pending=fun() -> [maps:get(from,R) || R <- maps:get(requests,ba_device_config:snapshot()),maps:get(key,R)=:=Key] end,
    ?assertEqual({error,waiting_for_approval},ba_device_config:request(Key,<<"PEER">>)),
    ?assertEqual({error,waiting_for_approval},ba_device_config:request(Key,<<"PEER">>)),
    ?assertEqual([<<"PEER">>],Pending()),
    ok=ba_device_config:answer(Key,false,#{}),
    ?assertEqual([],Pending()),
    ?assertEqual({error,declined},ba_device_config:request(Key,<<"PEER">>)),
    ?assertEqual({error,waiting_for_approval},ba_device_config:request(Key,<<"local">>)),
    ok=ba_device_config:answer(Key,true,#{}),
    ?assert(maps:get(Key,ba_app_session:consent())),
    ?assertEqual(ok,ba_device_config:request(Key,<<"PEER">>)),
    ?assertEqual([],Pending()),
    ok=ba_device_config:policy(Key,no,#{}),
    ?assertNot(maps:get(Key,ba_app_session:consent())),
    ?assertEqual({error,refused},ba_device_config:request(Key,<<"OTHER">>)),
    %% A policy change starts over: an earlier decline asks again under Ask.
    ok=ba_device_config:policy(Key,ask,#{}),
    ?assertEqual({error,waiting_for_approval},ba_device_config:request(Key,<<"PEER">>))
end).

restart_keeps_settings_not_history_test() -> fixture(fun(_) ->
    ok=ba_app_session:capability(microphone,true),
    ?assertEqual(<<"Enable microphone">>,maps:get(undo_label,ba_device_config:snapshot())),
    restart(),
    %% The Device starts from its settings; undo history lives only while it runs.
    ?assert(maps:get(microphone,ba_app_session:consent())),
    ?assertNot(maps:get(can_undo,ba_device_config:snapshot())),
    ok=ba_settings:flush(),gen_server:stop(ba_device_config),gen_server:stop(ba_settings),
    {ok,_}=ba_settings:start_link(),{ok,_}=ba_device_config:start_link(),
    ?assert(maps:get(microphone,ba_app_session:consent()))
end).

no_ops_and_errors_do_not_add_edits_test() -> fixture(fun(_) ->
    Before=ba_device_config:snapshot(),
    ok=ba_device_config:change(#{microphone => false},#{}),
    ?assertEqual({error,invalid_configuration},ba_device_config:change(#{microphone => yes},#{})),
    ?assertEqual({error,invalid_configuration},ba_device_config:change(#{new_setting => true},#{})),
    ?assertEqual(Before,ba_device_config:snapshot()),
    ?assertEqual({error,nothing_to_undo},ba_device_config:undo(#{})),
    ?assertEqual({error,nothing_to_redo},ba_device_config:redo(#{}))
end).

new_edit_after_undo_discards_redo_test() -> fixture(fun(_) ->
    ok=ba_device_config:change(#{microphone => true},#{}),
    ok=ba_device_config:change(#{speaker => false},#{}),
    ok=ba_device_config:undo(#{}),
    ok=ba_device_config:change(#{broadcast => true},#{}),
    ?assertNot(maps:get(can_redo,ba_device_config:snapshot())),
    ?assertEqual({error,nothing_to_redo},ba_device_config:redo(#{}))
end).

revision_and_retry_protect_multi_client_undo_test() -> fixture(fun(_) ->
    ok=ba_device_config:change(#{speaker => true},#{}),
    ok=ba_device_config:change(#{microphone => true},#{}),
    ok=ba_device_config:change(#{speaker => false},#{}),
    R=maps:get(revision,ba_device_config:snapshot()),
    ?assertEqual({error,configuration_changed},ba_device_config:undo(#{expected_revision => R-1})),
    Options=#{expected_revision => R,request_id => <<"undo-once">>},
    ?assertEqual({error,local_approval_required},ba_device_config:undo(Options)),
    ?assertEqual(R,maps:get(revision,ba_device_config:snapshot())),
    ?assert(maps:get(microphone,ba_device_config:consent())),
    ?assertNot(maps:get(speaker,ba_device_config:consent()))
end).

history_is_bounded_test() -> fixture(fun(_) ->
    [ok=ba_device_config:change(#{broadcast => N rem 2=:=1},#{}) || N <- lists:seq(1,120)],
    ?assertEqual(101,length(maps:get(entries,ba_device_config:snapshot()))),
    [ok=ba_device_config:undo(#{}) || _ <- lists:seq(1,100)],
    ?assertEqual({error,nothing_to_undo},ba_device_config:undo(#{})),
    ?assert(maps:get(can_redo,ba_device_config:snapshot()))
end).

internal_setter_and_bridge_share_one_owner_test() -> fixture(fun(_) ->
    Parent=self(),spawn(fun() -> Parent ! {done,ba_app_session:capability(microphone,true)} end),
    receive {done,ok} -> ok after 1000 -> error(no_internal_change) end,
    ?assertEqual(1,maps:get(revision,ba_device_config:snapshot())),
    ok=ba_device_config:change(#{microphone => false},#{}),
    ?assertEqual(2,maps:get(revision,ba_device_config:snapshot())),
    ?assertNot(maps:get(microphone,ba_app_session:consent()))
end).

restart() -> gen_server:stop(ba_device_config),{ok,_}=ba_device_config:start_link(),ok.
fixture(F) ->
    Env=[{K,os:getenv(K)} || K <- ["BA_STATE_DIR","BA_IDENTITY_SEED"]],
    Keys=[audio_automation,audio_capture_adapter,audio_output_adapter,buffee_default_permissions],
    Old=[{K,application:get_env(ba_core,K)} || K <- Keys],
    Dir=filename:join("/tmp","ba-config-"++integer_to_list(erlang:unique_integer([positive]))),
    ok=file:make_dir(Dir),os:putenv("BA_STATE_DIR",Dir),os:putenv("BA_IDENTITY_SEED",lists:duplicate(64,$A)),
    {ok,_}=ba_settings:start_link(),{ok,_}=ba_device_config:start_link(),
    try F(Dir) after
        gen_server:stop(ba_device_config),gen_server:stop(ba_settings),file:del_dir_r(Dir),
        [case V of false -> os:unsetenv(K);_ -> os:putenv(K,V) end || {K,V} <- Env],
        [case V of undefined -> application:unset_env(ba_core,K);{ok,X} -> application:set_env(ba_core,K,X) end || {K,V} <- Old]
    end.
