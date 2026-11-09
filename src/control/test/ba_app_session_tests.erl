-module(ba_app_session_tests).
-include_lib("eunit/include/eunit.hrl").
contract_is_scoped_to_receiver_and_source_test() ->
    Id=ba_app_session:contract(<<"swarm">>,<<"publisher">>,#{receiver => <<"one">>,source => <<"mic">>}),
    ?assert(ba_swarm_job:hex(Id,32)),
    ?assertEqual(Id,ba_app_session:contract(<<"swarm">>,<<"publisher">>,#{receiver => <<"one">>,source => <<"mic">>})),
    ?assertNotEqual(Id,ba_app_session:contract(<<"swarm">>,<<"publisher">>,#{receiver => <<"two">>,source => <<"mic">>})),
    ?assertNotEqual(Id,ba_app_session:contract(<<"swarm">>,<<"publisher">>,#{receiver => <<"one">>,source => <<"output">>})).
capability_reports_real_work_instead_of_permission_alone_test() ->
    Old=[{K,application:get_env(ba_core,K)} || K <- [audio_automation,audio_consent]],
    try
        application:set_env(ba_core,audio_automation,true),
        application:set_env(ba_core,audio_consent,#{speaker => true,microphone => true,broadcast => false}),
        S=#{active => #{},enabled => false,instance => binary:copy(<<"A">>,32),revision => 0,
            audio => #{speaker => #{state => ready},microphone => #{state => error},broadcast => #{state => disabled}}},
        {reply,Caps,_}=ba_device_handler:handle_call(capabilities,undefined,S),
        A=maps:get(<<"audio">>,Caps),
        ?assertMatch(#{<<"consent">> := true,<<"available">> := true},maps:get(<<"speaker">>,A)),
        ?assertMatch(#{<<"consent">> := true,<<"available">> := false},maps:get(<<"microphone">>,A)),
        ?assertMatch(#{<<"consent">> := false,<<"available">> := false},maps:get(<<"broadcast">>,A))
    after restore(Old) end.
exclusions_are_memory_only_test() ->
    Old=application:get_env(ba_core,runtime_profile),application:set_env(ba_core,runtime_profile,swarm_control),
    ets:new(ba_swarm_state,[named_table,public]),
    try
        Id=binary:copy(<<"A">>,64),?assertNot(ba_app_session:excluded(Id)),
        ok=ba_device_store:save(swarm_exclusions,[Id]),?assert(ba_app_session:excluded(Id)),
        ets:delete(ba_swarm_state),?assertNot(ba_app_session:excluded(Id))
    after
        case ets:whereis(ba_swarm_state) of undefined -> ok;_ -> ets:delete(ba_swarm_state) end,
        restore([{runtime_profile,Old}])
    end.
restore(Entries) -> [case V of undefined -> application:unset_env(ba_core,K);{ok,X} -> application:set_env(ba_core,K,X) end || {K,V} <- Entries],ok.

ios_configuration_discards_only_old_swarm_snapshots_test() ->
    Keys=[audio_automation,audio_capture_adapter,audio_output_adapter,swarm_default_permissions],
    Old=[{K,application:get_env(ba_core,K)} || K <- Keys],
    Platform=os:getenv("BA_PLATFORM"),State=os:getenv("BA_STATE_DIR"),
    Dir=filename:join("/tmp","ba-ios-migration-"++integer_to_list(erlang:unique_integer([positive]))),
    ok=file:make_dir(Dir),
    try
        [ok=file:write_file(filename:join(Dir,F),<<"keep or discard">>) || F <- ["swarm_member.term","contacts.term","identity.term"]],
        os:putenv("BA_PLATFORM","ios"),os:putenv("BA_STATE_DIR",Dir),
        ok=ba_app_session:configure(),
        ?assertEqual({ok,ba_ios_input},application:get_env(ba_core,audio_capture_adapter)),
        ?assertEqual({ok,ba_ios_audio},application:get_env(ba_core,audio_output_adapter)),
        ?assertEqual({ok,true},application:get_env(ba_core,audio_automation)),
        ?assertNot(filelib:is_file(filename:join(Dir,"swarm_member.term"))),
        ?assert(filelib:is_file(filename:join(Dir,"contacts.term"))),
        ?assert(filelib:is_file(filename:join(Dir,"identity.term")))
    after
        restore(Old),
        [case V of false -> os:unsetenv(K);_ -> os:putenv(K,V) end || {K,V} <- [{"BA_PLATFORM",Platform},{"BA_STATE_DIR",State}]],
        file:del_dir_r(Dir)
    end.
