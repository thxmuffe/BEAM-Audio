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
