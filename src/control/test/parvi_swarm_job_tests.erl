-module(parvi_swarm_job_tests).
-include_lib("eunit/include/eunit.hrl").

jobs_test_() ->
    {foreach,fun setup/0,fun cleanup/1,[
        fun acceptance_completion_retry/0,fun authorization_and_contract/0,
        fun expiry_does_not_renew/0,fun cancellation_and_tombstone/0,
        fun conflicting_offer/0,fun contract_and_session_cleanup/0,
        fun control_failure_cleanup/0,fun worker_failure_retry/0,fun bounded_deduplication/0]}.
setup() ->
    {ok,_} = application:ensure_all_started(crypto),
    {ok,Sup} = parvi_device_sup:start_link(),
    Control = spawn(fun control/0), true = register(parvi_swarm_control,Control),
    ok = parvi_device_handler:set_test_contract(director(),contract(),1),
    {Sup,Control}.
cleanup({Sup,Control}) -> gen_server:stop(Sup),exit(Control,kill).
control() ->
    receive
        {'$gen_call',From,{run,Fun}} -> gen_server:reply(From,Fun()),control();
        _ -> control()
    end.
run(Fun) -> gen_server:call(parvi_swarm_control,{run,Fun}).
director() -> binary:copy(<<"A">>,64).
contract() -> binary:copy(<<"B">>,32).
fresh() -> binary:encode_hex(crypto:strong_rand_bytes(16)).
context() -> #{peer => director(),director => director(),session => binary:copy(<<"C">>,32),
               swarm => binary:copy(<<"D">>,32),deadline => erlang:monotonic_time(millisecond)+60000}.
offer() -> #{<<"contract">> => contract(),<<"contract_revision">> => 1,
    <<"capability">> => <<"test">>,<<"duration_ms">> => 10000,<<"lease_ms">> => 10000}.
accept(Id,Offer) -> run(fun() -> parvi_device_handler:accept_job(context(),Id,Offer) end).
cancel(Id) -> run(fun() -> parvi_device_handler:cancel_job(context(),Id) end).
report(Id) -> maps:get(Id,maps:get(jobs,parvi_device_handler:status())).
workers() -> supervisor:which_children(parvi_device_worker_sup).
await(Fun) -> await(Fun,100).
await(_,0) -> error(job_did_not_converge);
await(Fun,N) -> case Fun() of true -> ok; false -> timer:sleep(10),await(Fun,N-1) end.

acceptance_completion_retry() ->
    ok = parvi_device_handler:enable_test(true), Id = fresh(), Offer = (offer())#{<<"duration_ms">> := 50},
    {ok,Accepted} = accept(Id,Offer), ?assertEqual(<<"accepted">>,maps:get(<<"state">>,Accepted)),
    {ok,Accepted} = accept(Id,Offer), ?assertEqual(1,length(workers())),
    await(fun() -> maps:get(<<"state">>,report(Id)) =:= <<"completed">> end),
    Completed = report(Id), ?assertEqual(maps:get(<<"attempt">>,Accepted),maps:get(<<"attempt">>,Completed)),
    {ok,Completed} = accept(Id,Offer), ?assertEqual([],workers()).

authorization_and_contract() ->
    Id = fresh(),
    ?assertEqual({error,not_control},parvi_device_handler:accept_job(context(),Id,offer())),
    {ok,Denied} = accept(Id,offer()), ?assertEqual(<<"consent_required">>,maps:get(<<"reason">>,Denied)),
    ok = parvi_device_handler:enable_test(true),
    {ok,Denied} = accept(Id,offer()), % A rejected ID never becomes a new acceptance on retry.
    {ok,Wrong} = accept(fresh(),(offer())#{<<"contract_revision">> := 2}),
    ?assertEqual(<<"contract_mismatch">>,maps:get(<<"reason">>,Wrong)),
    ok = parvi_device_handler:set_test_contract(director(),contract(),2),
    ?assertEqual({error,stale_contract},parvi_device_handler:set_test_contract(director(),contract(),1)),
    ?assertEqual([],workers()).

expiry_does_not_renew() ->
    ok = parvi_device_handler:enable_test(true), Id = fresh(), Offer = (offer())#{<<"lease_ms">> := 100},
    {ok,Accepted} = accept(Id,Offer),
    Original = maps:get(Id,maps:get(jobs,sys:get_state(parvi_device_handler))),
    timer:sleep(30), {ok,Accepted} = accept(Id,Offer),
    Retried = maps:get(Id,maps:get(jobs,sys:get_state(parvi_device_handler))),
    ?assertEqual(maps:get(deadline,Original),maps:get(deadline,Retried)),
    await(fun() -> maps:get(<<"state">>,report(Id)) =:= <<"expired">> end),
    ?assertEqual([],workers()), {ok,Expired} = accept(Id,Offer),
    ?assertEqual(<<"expired">>,maps:get(<<"state">>,Expired)).

cancellation_and_tombstone() ->
    ok = parvi_device_handler:enable_test(true), Id = fresh(),
    {ok,_} = accept(Id,offer()), {ok,Cancelled} = cancel(Id),
    ?assertEqual(<<"cancelled">>,maps:get(<<"state">>,Cancelled)),
    {ok,Cancelled} = cancel(Id), {ok,Cancelled} = accept(Id,offer()),
    Other = fresh(), {ok,_} = cancel(Other),
    {ok,Rejected} = accept(Other,offer()),
    ?assertEqual(<<"conflicting_offer">>,maps:get(<<"reason">>,Rejected)), ?assertEqual([],workers()).

conflicting_offer() ->
    ok = parvi_device_handler:enable_test(true), Id = fresh(),
    {ok,Accepted} = accept(Id,offer()),
    {ok,Conflict} = accept(Id,(offer())#{<<"duration_ms">> := 100}),
    ?assertEqual(<<"conflicting_offer">>,maps:get(<<"reason">>,Conflict)),
    {ok,OtherSession} = run(fun() -> parvi_device_handler:accept_job((context())#{session := fresh()},Id,offer()) end),
    ?assertEqual(<<"rejected">>,maps:get(<<"state">>,OtherSession)),
    ?assertEqual(Accepted,report(Id)), ?assertEqual(1,length(workers())).

contract_and_session_cleanup() ->
    ok = parvi_device_handler:enable_test(true),
    {ok,Local} = parvi_device_handler:start(test,#{duration_ms => 10000}),
    Id = fresh(), {ok,_} = accept(Id,offer()),
    ok = parvi_device_handler:clear_test_contract(),
    ?assertEqual(<<"contract_revoked">>,maps:get(<<"reason">>,report(Id))),
    ?assertEqual(1,length(workers())),
    ok = parvi_device_handler:set_test_contract(director(),contract(),2),
    New = fresh(), {ok,_} = accept(New,(offer())#{<<"contract_revision">> := 2}),
    C = context(), ok = run(fun() -> parvi_device_handler:session_down(director(),maps:get(session,C)) end),
    ?assertEqual(1,length(workers())),
    ?assert(maps:is_key(Local,maps:get(active,parvi_device_handler:status()))),
    ?assertEqual(#{},maps:get(jobs,parvi_device_handler:status())).

control_failure_cleanup() ->
    ok = parvi_device_handler:enable_test(true),
    {ok,_} = parvi_device_handler:start(test,#{duration_ms => 10000}),
    {ok,_} = accept(fresh(),offer()), exit(whereis(parvi_swarm_control),kill),
    await(fun() -> length(workers()) =:= 1 end),
    ?assertEqual(#{},maps:get(jobs,parvi_device_handler:status())).

worker_failure_retry() ->
    ok = parvi_device_handler:enable_test(true), Id = fresh(),
    {ok,_} = accept(Id,offer()), [{_,Pid,_,_}] = workers(), exit(Pid,kill),
    await(fun() -> maps:get(<<"state">>,report(Id)) =:= <<"failed">> end),
    {ok,Failed} = accept(Id,offer()), ?assertEqual(<<"failed">>,maps:get(<<"state">>,Failed)),
    ?assertEqual([],workers()), {ok,_} = accept(fresh(),offer()).

bounded_deduplication() ->
    [accept(fresh(),offer()) || _ <- lists:seq(1,32)],
    {ok,Report} = accept(fresh(),offer()),
    ?assertEqual(<<"job_limit">>,maps:get(<<"reason">>,Report)),
    ?assertEqual(32,map_size(maps:get(jobs,parvi_device_handler:status()))),
    ?assertEqual([],workers()).
