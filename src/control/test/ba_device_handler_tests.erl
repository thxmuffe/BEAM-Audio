-module(ba_device_handler_tests).
-include_lib("eunit/include/eunit.hrl").

device_handler_test_() ->
    {foreach,fun setup/0,fun cleanup/1,[
        fun consent_and_arguments/0,fun completion/0,fun capacity_and_cancel/0,
        fun consent_withdrawal/0,fun worker_crash_recovery/0,fun handler_crash_cleanup/0,
        fun worker_supervisor_crash/0,fun stale_events/0,fun bounded_history/0]}.
setup() ->
    {ok,_} = application:ensure_all_started(crypto),
    {ok,Sup} = ba_device_sup:start_link(), Sup.
cleanup(Sup) -> gen_server:stop(Sup).
test_cap() -> maps:get(<<"test">>,ba_device_handler:capabilities()).
start(Duration) -> ba_device_handler:start(test,#{duration_ms => Duration}).
pid(Id) ->
    [Pid] = [P || {I,P,_,_} <- supervisor:which_children(ba_device_worker_sup),I =:= Id], Pid.
active() -> maps:get(active,ba_device_handler:status()).
outcome(Id) ->
    case [State || #{id := I,state := State} <- maps:get(history,ba_device_handler:status()),I =:= Id] of
        [State] -> State;
        [] -> pending
    end.
await(Predicate) -> await(Predicate,100).
await(_,0) -> error(state_did_not_converge);
await(Predicate,N) ->
    case Predicate() of true -> ok; false -> timer:sleep(10),await(Predicate,N-1) end.

consent_and_arguments() ->
    ?assertMatch(#{<<"supported">> := true,<<"available">> := false,<<"consent">> := false},test_cap()),
    ?assertEqual({error,consent_required},start(100)),
    ok = ba_device_handler:enable_test(true),
    [?assertEqual({error,unsupported_capability_or_arguments},start(D)) || D <- [0,19,10001,1.5]],
    ?assertEqual({error,unsupported_capability_or_arguments},ba_device_handler:start(microphone,#{})),
    ?assertEqual({error,unsupported_capability_or_arguments},ba_device_handler:start(test,#{duration_ms => 100,module => os})),
    ?assertEqual([],supervisor:which_children(ba_device_worker_sup)).

completion() ->
    ok = ba_device_handler:enable_test(true),
    {ok,Id} = start(50),
    await(fun() -> maps:get(state,maps:get(Id,active())) =:= running end),
    await(fun() -> outcome(Id) =:= completed end),
    ?assertEqual(#{},active()),
    ?assertEqual(0,maps:get(<<"active">>,test_cap())).

capacity_and_cancel() ->
    ok = ba_device_handler:enable_test(true),
    {ok,A} = start(10000),{ok,B} = start(10000), Pid = pid(A),
    ?assertEqual({error,capacity_exceeded},start(10000)),
    ?assertEqual(false,maps:get(<<"available">>,test_cap())),
    ok = ba_device_handler:cancel(A),
    ?assertNot(is_process_alive(Pid)),
    ?assertEqual(cancelled,outcome(A)),
    ?assert(maps:is_key(B,active())),
    ok = ba_device_handler:cancel(A),
    {ok,_} = start(10000),
    ?assertEqual(2,map_size(active())).

consent_withdrawal() ->
    ok = ba_device_handler:enable_test(true),
    {ok,A} = start(10000),{ok,B} = start(10000),
    Pids = [pid(A),pid(B)],
    ok = ba_device_handler:enable_test(false),
    [?assertNot(is_process_alive(P)) || P <- Pids],
    ?assertEqual([consent_revoked,consent_revoked],[outcome(A),outcome(B)]),
    ?assertEqual({error,consent_required},start(100)).

worker_crash_recovery() ->
    ok = ba_device_handler:enable_test(true),
    Handler = whereis(ba_device_handler),
    {ok,A} = start(10000), {ok,B} = start(10000), Other = pid(B),
    Attempt = maps:get(attempt,maps:get(A,active())), exit(pid(A),kill),
    await(fun() -> outcome(A) =:= failed end),
    ?assertEqual(Handler,whereis(ba_device_handler)),
    ?assert(is_process_alive(Other)),
    ?assertEqual(1,length(supervisor:which_children(ba_device_worker_sup))),
    {ok,C} = start(10000),
    ?assertNotEqual(Attempt,maps:get(attempt,maps:get(C,active()))),
    ?assertEqual(2,map_size(active())).

handler_crash_cleanup() ->
    ok = ba_device_handler:enable_test(true),
    {ok,A} = start(10000), Worker = pid(A),
    Handler = whereis(ba_device_handler), Workers = whereis(ba_device_worker_sup),
    OldInstance = maps:get(<<"instance">>,ba_device_handler:capabilities()),
    exit(Handler,kill),
    await(fun() -> is_pid(whereis(ba_device_handler)) andalso
        whereis(ba_device_handler) =/= Handler andalso
        is_pid(whereis(ba_device_worker_sup)) andalso whereis(ba_device_worker_sup) =/= Workers end),
    ?assertNot(is_process_alive(Worker)),
    ?assertEqual([],supervisor:which_children(ba_device_worker_sup)),
    ?assertNotEqual(OldInstance,maps:get(<<"instance">>,ba_device_handler:capabilities())),
    ?assertEqual({error,consent_required},start(100)),
    ok = ba_device_handler:enable_test(true), {ok,_} = start(10000).

worker_supervisor_crash() ->
    ok = ba_device_handler:enable_test(true),
    {ok,A} = start(10000), Worker = pid(A),
    Handler = whereis(ba_device_handler), Workers = whereis(ba_device_worker_sup),
    exit(Workers,kill),
    await(fun() -> outcome(A) =:= failed andalso is_pid(whereis(ba_device_worker_sup)) andalso
        whereis(ba_device_worker_sup) =/= Workers end),
    ?assertNot(is_process_alive(Worker)),
    ?assertEqual(Handler,whereis(ba_device_handler)),
    {ok,_} = start(10000).

stale_events() ->
    ok = ba_device_handler:enable_test(true), {ok,A} = start(10000),
    await(fun() -> maps:get(state,maps:get(A,active())) =:= running end),
    W = maps:get(A,active()), Handler = whereis(ba_device_handler),
    Handler ! {worker_event,self(),A,maps:get(attempt,W),completed},
    Handler ! {worker_event,pid(A),A,<<"old-attempt">>,completed},
    ?assertEqual(running,maps:get(state,maps:get(A,active()))),
    ok = ba_device_handler:cancel(A),
    Handler ! {worker_event,self(),A,maps:get(attempt,W),ready},
    ?assertEqual(#{},active()).

bounded_history() ->
    ok = ba_device_handler:enable_test(true),
    [begin {ok,Id} = start(10000),ok = ba_device_handler:cancel(Id) end || _ <- lists:seq(1,20)],
    ?assertEqual(16,length(maps:get(history,ba_device_handler:status()))),
    ?assertEqual(#{},active()).
