-module(ba_app_session_tests).
-include_lib("eunit/include/eunit.hrl").
contract_is_scoped_to_receiver_and_source_test() ->
    Id=ba_app_session:contract(<<"session">>,<<"publisher">>,#{receiver => <<"one">>,source => <<"mic">>}),
    ?assert(ba_hex:valid(Id,32)),
    ?assertEqual(Id,ba_app_session:contract(<<"session">>,<<"publisher">>,#{receiver => <<"one">>,source => <<"mic">>})),
    ?assertNotEqual(Id,ba_app_session:contract(<<"session">>,<<"publisher">>,#{receiver => <<"two">>,source => <<"mic">>})),
    ?assertNotEqual(Id,ba_app_session:contract(<<"session">>,<<"publisher">>,#{receiver => <<"one">>,source => <<"output">>})).
capability_reports_real_work_instead_of_permission_alone_test() ->
    Old=[{K,application:get_env(ba_core,K)} || K <- [audio_automation]],
    try
        application:set_env(ba_core,audio_automation,true),
        ba_test_consent:with(#{speaker => true,microphone => true},fun() ->
        S=#{active => #{},enabled => false,instance => binary:copy(<<"A">>,32),revision => 0,
            audio => #{speaker => #{state => ready},microphone => #{state => error},broadcast => #{state => disabled}}},
        {reply,Caps,_}=ba_device_handler:handle_call(capabilities,undefined,S),
        A=maps:get(<<"audio">>,Caps),
        ?assertMatch(#{<<"consent">> := true,<<"available">> := true},maps:get(<<"speaker">>,A)),
        ?assertMatch(#{<<"consent">> := true,<<"available">> := false},maps:get(<<"microphone">>,A)),
        ?assertMatch(#{<<"consent">> := false,<<"available">> := false},maps:get(<<"broadcast">>,A))
        end)
    after restore(Old) end.
exclusions_are_memory_only_test() ->
    ets:new(ba_session_state,[named_table,public]),
    try
        Id=binary:copy(<<"A">>,64),?assertNot(ba_app_session:excluded(Id)),
        ok=ba_device_store:save(session_exclusions,[Id]),?assert(ba_app_session:excluded(Id)),
        ets:delete(ba_session_state),?assertNot(ba_app_session:excluded(Id))
    after
        case ets:whereis(ba_session_state) of undefined -> ok;_ -> ets:delete(ba_session_state) end
    end.
restore(Entries) -> [case V of undefined -> application:unset_env(ba_core,K);{ok,X} -> application:set_env(ba_core,K,X) end || {K,V} <- Entries],ok.

apple_configuration_preserves_session_memory_test_() ->
    [?_test(apple_configuration_preserves_session_memory(Platform)) || Platform <- ["mac","ios"]].
apple_configuration_preserves_session_memory(PlatformName) ->
    Keys=[audio_automation,audio_capture_adapter,audio_output_adapter,restore_session_on_start],
    Old=[{K,application:get_env(ba_core,K)} || K <- Keys],
    Platform=os:getenv("BA_PLATFORM"),State=os:getenv("BA_STATE_DIR"),
    Dir=filename:join("/tmp","ba-apple-memory-"++integer_to_list(erlang:unique_integer([positive]))),
    ok=file:make_dir(Dir),
    try
        [ok=file:write_file(filename:join(Dir,F),<<"saved session policy">>) || F <- ["saved_sessions.term","contacts.term","identity.term","session_connection.term"]],
        os:putenv("BA_PLATFORM",PlatformName),os:putenv("BA_STATE_DIR",Dir),
        ok=ba_app_session:configure(),
        ?assertEqual({ok,case PlatformName of "mac" -> ba_mac_native_audio;"ios" -> ba_no_capture end},application:get_env(ba_core,audio_capture_adapter)),
        ?assertEqual({ok,true},application:get_env(ba_core,audio_automation)),
        ?assertEqual({ok,true},application:get_env(ba_core,restore_session_on_start)),
        ?assert(filelib:is_file(filename:join(Dir,"session_connection.term"))),
        ?assertEqual({ok,<<"saved session policy">>},file:read_file(filename:join(Dir,"saved_sessions.term"))),
        ?assert(filelib:is_file(filename:join(Dir,"contacts.term"))),
        ?assert(filelib:is_file(filename:join(Dir,"identity.term")))
    after
        restore(Old),
        [case V of false -> os:unsetenv(K);_ -> os:putenv(K,V) end || {K,V} <- [{"BA_PLATFORM",Platform},{"BA_STATE_DIR",State}]],
        file:del_dir_r(Dir)
    end.

%% Capture the platform cannot provide is reported up front for every UI.
unavailable_capabilities_from_capture_adapter_test() ->
    Old=application:get_env(ba_core,audio_capture_adapter),
    try
        application:set_env(ba_core,audio_capture_adapter,ba_mac_native_audio),
        ?assertEqual([<<"microphone">>],maps:keys(ba_app_session:unavailable_capabilities())),
        application:unset_env(ba_core,audio_capture_adapter),
        ?assertEqual(#{},ba_app_session:unavailable_capabilities())
    after case Old of undefined -> application:unset_env(ba_core,audio_capture_adapter);{ok,V} -> application:set_env(ba_core,audio_capture_adapter,V) end end.
