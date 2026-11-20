-module(ba_inspection_tests).
-include_lib("eunit/include/eunit.hrl").

logs_require_inspect_for_every_chunk_test() ->
    ba_test_consent:with(#{inspect => false},fun() ->
        Old=os:getenv("BA_STATE_DIR"),
        Dir=filename:join("/tmp","ba-inspection-"++integer_to_list(erlang:unique_integer([positive]))),
        ok=file:make_dir(Dir),os:putenv("BA_STATE_DIR",Dir),
        Path=filename:join(Dir,"runtime.log"),Data=binary:copy(<<"diagnostic line\n">>,1000),
        ok=file:write_file(Path,Data),
        Q=#{<<"log">> => <<"runtime.log">>,<<"offset">> => 0,<<"length">> => 8192},
        try
            ok=ba_device_config:policy(inspect,no,#{}),
            ?assertEqual({error,refused},ba_inspection:read(Q,<<"Inspector">>)),
            ?assertEqual({error,refused},ba_inspection:capabilities(true,<<"Inspector">>)),
            ok=ba_device_config:policy(inspect,ask,#{}),
            ?assertEqual({error,waiting_for_approval},ba_inspection:read(Q,<<"Inspector">>)),
            ?assertEqual({error,waiting_for_approval},ba_inspection:capabilities(true,<<"Inspector">>)),
            ?assertMatch([#{key := inspect,from := <<"Inspector">>}],maps:get(requests,ba_device_config:snapshot())),
            ok=ba_device_config:answer(inspect,false,#{}),
            ?assertEqual({error,declined},ba_inspection:read(Q,<<"Inspector">>)),
            ?assertEqual({error,declined},ba_inspection:capabilities(true,<<"Inspector">>)),
            ok=ba_device_config:policy(inspect,ask,#{}),
            ?assertEqual({error,waiting_for_approval},ba_inspection:read(Q,<<"Inspector">>)),
            ok=ba_device_config:answer(inspect,true,#{}),
            {ok,First}=ba_inspection:read(Q,<<"Inspector">>),
            ?assertEqual(ok,ba_inspection:validate_reply(First)),
            ?assertEqual(binary:part(Data,0,8192),base64:decode(maps:get(<<"data">>,First))),
            Next=Q#{<<"offset">> := 8192,<<"version">> => maps:get(<<"version">>,First)},
            ok=ba_device_config:policy(inspect,no,#{}),
            ?assertEqual({error,refused},ba_inspection:read(Next,<<"Inspector">>)),
            ok=ba_device_config:policy(inspect,always,#{}),
            {ok,Last}=ba_inspection:read(Next,<<"Inspector">>),
            ?assert(maps:get(<<"eof">>,Last)),
            ?assertEqual(Data,<<(base64:decode(maps:get(<<"data">>,First)))/binary,
                                (base64:decode(maps:get(<<"data">>,Last)))/binary>>),
            ok=file:rename(Path,Path++".0"),ok=file:write_file(Path,<<"replacement log\n">>),
            ?assertEqual({error,log_rotated},ba_inspection:read(Next,<<"Inspector">>))
        after file:del_dir_r(Dir),case Old of false -> os:unsetenv("BA_STATE_DIR");_ -> os:putenv("BA_STATE_DIR",Old) end end
    end).

only_bounded_named_log_reads_test() ->
    Q=#{<<"log">> => <<"runtime.log">>,<<"offset">> => 0,<<"length">> => 8192},
    [?assertException(error,_,ba_inspection:validate_request(P)) || P <-
        [Q#{<<"log">> := <<"../identity.seed">>},Q#{<<"log">> := <<"settings.config">>},
         Q#{<<"offset">> := -1},Q#{<<"length">> := 8193},Q#{<<"extra">> => true}]].
