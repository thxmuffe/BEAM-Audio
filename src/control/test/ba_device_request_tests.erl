-module(ba_device_request_tests).
-include_lib("eunit/include/eunit.hrl").

authorize_test() ->
    A = fun ba_device_request:authorize/3,
    ?assertEqual(ok,A(<<"status.read">>,#{},[status_read])),
    ?assertEqual({error,forbidden},A(<<"status.read">>,#{},[capabilities_read])),
    ?assertEqual(ok,A(<<"job.cancel">>,#{},[job_offer])),
    ?assertEqual({error,forbidden},A(<<"stream.message">>,#{<<"kind">> => <<"subscribe">>},[stream_read])),
    %% Stream kinds other than catalogue and subscribe need no Session right.
    ?assertEqual(ok,A(<<"stream.message">>,#{<<"kind">> => <<"other">>},[])),
    %% The shared offset is a Session setting: grant or on_air suffices.
    Set = #{<<"kind">> => <<"offset.set">>},
    ?assertEqual(ok,A(<<"time.message">>,Set,[stream_publish])),
    ?assertEqual(ok,A(<<"time.message">>,Set,[owner])),
    ?assertEqual({error,forbidden},A(<<"time.message">>,Set,[offset_write,time_read])),
    ?assertEqual({error,forbidden},A(<<"time.message">>,#{<<"kind">> => <<"offset.get">>},[])),
    %% Chat and replies need no right.
    ?assertEqual(ok,A(<<"chat.message">>,#{},[])),
    ?assertEqual(ok,A(<<"status.reply">>,#{},[])).

session_requests_test() ->
    A = fun(Kind,Perms) -> ba_device_request:authorize(<<"session.request">>,#{<<"kind">> => Kind},Perms) end,
    ?assertEqual(ok,A(<<"privilege_request">>,[])),
    ?assertEqual(ok,A(<<"privilege_release">>,[])),
    ?assertEqual({error,forbidden},A(<<"rename_request">>,[owner])),
    ?assertEqual(ok,A(<<"rename_request">>,[stream_publish])),
    ?assertEqual({error,forbidden},A(<<"remove_request">>,[owner,stream_publish])),
    ?assertEqual(ok,A(<<"remove_request">>,[end_session])),
    ?assertEqual({error,forbidden},A(<<"ended">>,[owner])),
    ?assertEqual(ok,A(<<"ended">>,[end_session])).
