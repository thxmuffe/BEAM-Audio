-module(parvi_clock_tests).
-include_lib("eunit/include/eunit.hrl").
-export([start_application/3,start_application/4,jump_reference/1]).

startup_anchor_is_not_polled_test_() -> {timeout,10,fun startup_anchor_is_not_polled/0}.
startup_anchor_is_not_polled() ->
    {Server,Port,Count} = ntp_server(),
    try with_local({ntp,"127.0.0.1",Port},30,fun() ->
        await(fun() -> maps:get(state,parvi_clock:status()) =:= synchronized end),
        ?assertEqual(1,atomics:get(Count,1)),
        {ok,Before} = parvi_clock:now(),
        timer:sleep(180), % Six accelerated internal periods; no upstream polling.
        ?assertEqual(1,atomics:get(Count,1)),
        ?assertEqual(1,maps:get(upstream_acquisitions,parvi_clock:status())),
        {ok,After} = parvi_clock:now(), ?assert(After > Before),
        ok = parvi_clock:set_reference(auto), timer:sleep(30),
        ?assertEqual(1,atomics:get(Count,1)),
        ok = parvi_clock:resync(), timer:sleep(30),
        ?assertEqual(1,atomics:get(Count,1)), % Explicit resync still respects server spacing.
        ?assertEqual({error,reference_changed},parvi_clock:peer_sample(wrong_scope,whereis(parvi_clock)))
    end) after exit(Server,kill) end.

production_cadence_test() ->
    with_local(system,undefined,fun() ->
        await(fun() -> maps:get(state,parvi_clock:status()) =:= synchronized end),
        D = parvi_clock:status(),
        ?assertEqual(30000,maps:get(interval_ms,D)),
        ?assertEqual(5000,maps:get(sample_interval_ms,D)),
        ?assertEqual(20,maps:get(filter_required_samples,D)),
        ?assertEqual(2000000,maps:get(threshold_ns,D)),
        ?assertEqual(1,maps:get(filter_sample_count,D)), % One real root anchor, no fabricated samples.
        ?assertMatch({ok,_},parvi_clock:filtered_utc_time())
    end).

remembered_peer_discovery_precedes_upstream_test() ->
    with_services(system,30,true,fun() ->
        {ok,Trust} = parvi_cluster_trust:start_link(self()),
        try
            {ok,Policy} = parvi_cluster_trust:create(),
            ok = gen_server:stop(parvi_clock),
            Members = maps:get(<<"members">>,Policy),
            Missing = #{<<"node">> => <<"clock_missing@localhost">>,
                <<"membership">> => <<"fixture">>, <<"via">> => null},
            ok = parvi_cluster_trust:install(Policy#{<<"revision">> := 2,
                <<"members">> := Members#{binary:copy(<<"0">>,64) => Missing}}),
            application:set_env(parvi,clock_peer_discovery_ms,150),
            {ok,_} = start_clock(),
            timer:sleep(50),
            ?assertEqual(0,maps:get(upstream_acquisitions,parvi_clock:status())),
            await(fun() -> maps:get(upstream_acquisitions,parvi_clock:status()) =:= 1 end),
            ?assertEqual(holdover,maps:get(state,parvi_clock:status())),
            ok = parvi_cluster_trust:retire()
        after
            case whereis(parvi_cluster_authority) of
                undefined -> ok;
                P -> try gen_server:stop(P) catch exit:noproc -> ok end
            end,
            gen_server:stop(Trust)
        end
    end).

native_membership_controls_clock_scope_test() ->
    with_services(system,30,true,fun() ->
        ?assertMatch(#{state := waiting_for_cluster},parvi_clock:status()),
        {ok,Trust} = parvi_cluster_trust:start_link(self()),
        try
            ?assertEqual(undefined,parvi_cluster_trust:snapshot()),
            {ok,Policy} = parvi_cluster_trust:create(),
            await(fun() -> maps:get(state,parvi_clock:status()) =:= synchronized end),
            ?assertEqual(Policy,parvi_cluster_trust:snapshot()),
            ?assertEqual(complete,maps:get(coverage,parvi_clock:status())),
            ok = parvi_cluster_trust:retire(),
            await(fun() -> maps:get(state,parvi_clock:status()) =:= waiting_for_cluster end),
            ?assertEqual({error,waiting_for_cluster},parvi_clock:now())
        after
            case whereis(parvi_cluster_authority) of
                undefined -> ok;
                P -> try gen_server:stop(P) catch exit:noproc -> ok end
            end,
            gen_server:stop(Trust)
        end
    end).

master_recreation_and_async_pulls_test_() -> {timeout,30,fun master_recreation_and_async_pulls/0}.
master_recreation_and_async_pulls() ->
    Cookie = atom_to_list(erlang:get_cookie()),
    Paths = lists:append([["-pa",P] || P <- code:get_path(), filelib:is_dir(P)]),
    Suffix = integer_to_list(erlang:unique_integer([positive])),
    Options = #{connection => standard_io, host => "127.0.0.1", longnames => true,
        args => ["+S","1:1","-setcookie",Cookie,
                 "-kernel","inet_dist_use_interface","{127,0,0,1}"] ++ Paths},
    {ok,A,ANode} = peer:start_link(Options#{name => list_to_atom("clock_a_"++Suffix)}),
    try
        ok = peer:call(A,?MODULE,start_application,[system,50,auto]),
        APid = peer:call(A,erlang,whereis,[parvi_clock]),
        await(fun() -> maps:get(state,peer:call(A,parvi_clock,status,[])) =:= synchronized end),
        {ok,B,_BNode} = peer:start_link(Options#{name => list_to_atom("clock_b_"++Suffix)}),
        try
            ok = peer:call(B,?MODULE,start_application,[system,50,{node,ANode}]),
            true = peer:call(B,net_kernel,connect_node,[ANode]),
            Group = {parvi,clock,local},
            await(fun() -> length(peer:call(B,pg,get_members,[parvi_pg,Group])) =:= 1 end),
            ok = peer:call(B,parvi_clock,set_reference,[auto]),
            await(fun() -> follower(B,ANode) end),
            ?assertEqual(maps:get(instance,peer:call(A,parvi_clock,status,[])),
                         maps:get(master_instance,peer:call(B,parvi_clock,status,[]))),
            {ok,A1} = peer:call(A,parvi_clock,now,[]),
            {ok,BTime} = peer:call(B,parvi_clock,now,[]),
            {ok,A2} = peer:call(A,parvi_clock,now,[]),
            ?assert(BTime >= A1-10000000 andalso BTime =< A2+10000000),
            ?assertEqual(0,maps:get(upstream_acquisitions,peer:call(B,parvi_clock,status,[]))),
            BPid = peer:call(B,erlang,whereis,[parvi_clock]),
            ok = peer:call(B,sys,suspend,[parvi_clock]),
            try
                timer:sleep(180),
                {messages,Messages} = peer:call(B,erlang,process_info,[BPid,messages]),
                ?assertEqual(1,length([tick || tick <- Messages]))
            after peer:call(B,sys,resume,[parvi_clock]) end,
            await(fun() -> follower(B,ANode) end),
            %% The master's clock mailbox is not on the read-only sample path.
            Count = maps:get(requests_served,peer:call(A,parvi_clock,status,[])),
            ok = peer:call(A,sys,suspend,[parvi_clock]),
            try
                await(fun() -> maps:get(requests_served,peer:call(A,parvi_clock,status,[])) > Count end)
            after peer:call(A,sys,resume,[parvi_clock]) end,
            Timeline = maps:get(timeline,peer:call(B,parvi_clock,status,[])),
            ok = peer:call(A,supervisor,terminate_child,[parvi_clock_sup,parvi_clock]),
            await(fun() -> maps:get(role,peer:call(B,parvi_clock,status,[])) =:= master end),
            ?assertEqual(0,maps:get(upstream_acquisitions,peer:call(B,parvi_clock,status,[]))),
            ?assertEqual(Timeline,maps:get(timeline,peer:call(B,parvi_clock,status,[]))),
            {ok,NewAPid} = peer:call(A,supervisor,restart_child,[parvi_clock_sup,parvi_clock]),
            ?assertNotEqual(APid,NewAPid),
            await(fun() -> follower(B,ANode) andalso
                maps:get(state,peer:call(A,parvi_clock,status,[])) =:= synchronized end),
            ?assertEqual(0,maps:get(upstream_acquisitions,peer:call(A,parvi_clock,status,[]))),
            ?assertEqual(Timeline,maps:get(timeline,peer:call(A,parvi_clock,status,[]))),
            ?assertEqual({error,reference_changed},peer:call(A,parvi_clock,peer_sample,[Group,APid]))
        after peer:stop(B) end
    after peer:stop(A) end.


filtered_sampling_and_separate_correction_test_() -> {timeout,20,fun filtered_sampling_and_separate_correction/0}.
filtered_sampling_and_separate_correction() ->
    Cookie = atom_to_list(erlang:get_cookie()),
    Paths = lists:append([["-pa",P] || P <- code:get_path(), filelib:is_dir(P)]),
    Suffix = integer_to_list(erlang:unique_integer([positive])),
    Options = #{connection => standard_io, host => "127.0.0.1", longnames => true,
        args => ["+S","1:1","-setcookie",Cookie,
                 "-kernel","inet_dist_use_interface","{127,0,0,1}"] ++ Paths},
    {ok,A,ANode} = peer:start_link(Options#{name => list_to_atom("filtered_a_"++Suffix)}),
    try
        ok = peer:call(A,?MODULE,start_application,[system,600,auto]),
        await(fun() -> maps:get(state,peer:call(A,parvi_clock,status,[])) =:= synchronized end),
        {ok,B,_} = peer:start_link(Options#{name => list_to_atom("filtered_b_"++Suffix)}),
        try
            %% Accelerate the independent timers: 10 ms sampling, 600 ms checking.
            ok = peer:call(B,?MODULE,start_application,[system,600,{node,ANode},10]),
            true = peer:call(B,net_kernel,connect_node,[ANode]),
            await(fun() -> maps:get(filter_sample_count,peer:call(B,parvi_clock,status,[])) >= 1 end),
            Initial = peer:call(B,parvi_clock,status,[]),
            ?assertNot(maps:get(filter_ready,Initial)),
            Revision = maps:get(revision,Initial),
            ok = peer:call(A,?MODULE,jump_reference,[10000000]),
            await(fun() -> maps:get(filter_ready,peer:call(B,parvi_clock,status,[])) end),
            Ready = peer:call(B,parvi_clock,status,[]),
            ?assertEqual(20,maps:get(filter_sample_count,Ready)),
            ?assertEqual(Revision,maps:get(revision,Ready)), % Sampling alone did not correct.
            await(fun() -> maps:get(revision,peer:call(B,parvi_clock,status,[])) > Revision end),
            Corrected = peer:call(B,parvi_clock,status,[]),
            ?assert(maps:get(remaining_correction_ns,Corrected) > 2000000),
            ?assertEqual(0,maps:get(upstream_acquisitions,Corrected)),
            ok = peer:call(B,parvi_clock,set_reference,[auto]),
            await(fun() -> maps:get(filter_sample_count,peer:call(B,parvi_clock,status,[])) < 20 end),
            ?assertNot(maps:get(filter_ready,peer:call(B,parvi_clock,status,[])))
        after peer:stop(B) end
    after peer:stop(A) end.

%% Change only a disposable test peer's reference, never the machine clock.
jump_reference(Delta) ->
    _ = sys:replace_state(parvi_clock,fun(#{clock := D} = S) ->
        T = erlang:monotonic_time(nanosecond),
        Offset = parvi_clock_mapping:offset(maps:get(mapping,D),T),
        Next = D#{mapping := parvi_clock_mapping:new(T,Offset+Delta)},
        ets:insert(parvi_clock,{clock,Next}), S#{clock := Next}
    end), ok.

follower(Peer,Master) ->
    D = peer:call(Peer,parvi_clock,status,[]),
    maps:get(role,D) =:= follower andalso maps:get(master,D) =:= Master andalso
        maps:get(state,D) =:= synchronized.

start_services(Source,Interval) ->
    {ok,_} = application:ensure_all_started(crypto),
    application:set_env(parvi,native_desk,false),
    application:set_env(parvi,clock_reference,auto),
    application:set_env(parvi,clock_upstream,Source),
    case Interval of
        undefined -> application:unset_env(parvi,clock_interval_ms);
        _ -> application:set_env(parvi,clock_interval_ms,Interval)
    end,
    {ok,_} = pg:start_link(parvi_pg), {ok,_} = parvi_chat:start_link(), ok.
start_clock() -> parvi_clock:start_link().
start_application(Source,Interval,Reference) ->
    start_application(Source,Interval,Reference,max(1,Interval div 6)).
start_application(Source,Interval,Reference,SampleInterval) ->
    application:load(parvi),
    application:set_env(parvi,native_desk,false),
    application:set_env(parvi,clock_reference,Reference),
    application:set_env(parvi,clock_upstream,Source),
    application:set_env(parvi,clock_interval_ms,Interval),
    application:set_env(parvi,clock_sample_interval_ms,SampleInterval),
    {ok,_} = parvi:start(native_cluster), ok.

with_local(Source,Interval,Fun) ->
    with_services(Source,Interval,false,Fun).
with_services(Source,Interval,NativeDesk,Fun) ->
    Keys = [native_desk,clock_reference,clock_upstream,clock_interval_ms,clock_peer_discovery_ms],
    Saved = [{K,application:get_env(parvi,K)} || K <- Keys],
    try
        ok = start_services(Source,Interval), application:set_env(parvi,native_desk,NativeDesk),
        {ok,_} = start_clock(), Fun()
    after
        [case whereis(N) of undefined -> ok; P -> gen_server:stop(P) end
         || N <- [parvi_clock,parvi_chat,parvi_pg]],
        [case V of undefined -> application:unset_env(parvi,K); {ok,X} -> application:set_env(parvi,K,X) end
         || {K,V} <- Saved]
    end.

await(Predicate) -> await(Predicate,200).
await(_,0) -> error(clock_did_not_converge);
await(Predicate,N) ->
    case Predicate() of true -> ok; false -> timer:sleep(10), await(Predicate,N-1) end.

ntp_server() ->
    {ok,Socket} = gen_udp:open(0,[binary,{active,false},{ip,{127,0,0,1}}]),
    {ok,{_,Port}} = inet:sockname(Socket), Count = atomics:new(1,[]),
    Pid = spawn(fun() -> receive {socket,S} -> ntp_loop(S,Count) end end),
    ok = gen_udp:controlling_process(Socket,Pid), Pid ! {socket,Socket}, {Pid,Port,Count}.
ntp_loop(Socket,Count) ->
    case gen_udp:recv(Socket,0) of
        {ok,{IP,Port,<<_:40/binary,Originate:64>>}} ->
            atomics:add(Count,1,1), T2 = ntp_stamp(), T3 = ntp_stamp(),
            ok = gen_udp:send(Socket,IP,Port,
                <<0:2,4:3,4:3,1:8,0:16,0:32,0:32,0:32,0:64,Originate:64,T2:64,T3:64>>),
            ntp_loop(Socket,Count);
        {error,closed} -> ok
    end.
ntp_stamp() ->
    T = erlang:system_time(nanosecond),
    (((T div 1000000000 + 2208988800) rem 4294967296) bsl 32) bor
        ((T rem 1000000000) * 4294967296 div 1000000000).
