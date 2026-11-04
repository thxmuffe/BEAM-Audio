%% Local clock owner. pg discovers peers; erpc pulls samples without a master sweep.
-module(parvi_clock).
-behaviour(gen_server).
-export([start_link/0, id/0, now/0, from_monotonic/1, to_monotonic/1, map_times/1,
         filtered_utc_time/0, status/0, set_reference/1, resync/0, reference_sample/0, peer_sample/2, seed_sample/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).
-define(CHECK_MS, 30000).
-define(SAMPLE_MS, 5000).
-define(FILTER_SAMPLES, 20).
-define(THRESHOLD_NS, 2000000).

start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).
id() -> <<"parvi-utc-posix-ns/v1">>.
now() -> filtered_utc_time().
filtered_utc_time() -> from_monotonic(mono()).
from_monotonic(Time) when is_integer(Time) ->
    case map_times([Time]) of {ok, [UTC]} -> {ok, UTC}; Error -> Error end.
map_times(Times) ->
    case mapping() of
        {ok, M} -> {ok, [parvi_clock_mapping:from_monotonic(M, T) || T <- Times]};
        Error -> Error
    end.
to_monotonic(Time) when is_integer(Time) ->
    case mapping() of
        {ok, M} -> {ok, parvi_clock_mapping:to_monotonic(M, Time)};
        Error -> Error
    end.
set_reference(Reference) -> gen_server:call(?MODULE, {reference, Reference}).
resync() -> gen_server:call(?MODULE, resync).

status() ->
    case snapshot() of
        #{mapping := Mapping} = D when is_map(Mapping) ->
            T = mono(), Age = max(0, T - maps:get(last_sync, D)),
            State = case maps:get(role, D) of
                waiting -> waiting_for_cluster;
                _ when map_get(coverage,D) =:= partial -> holdover;
                master -> synchronized;
                follower when Age > 2 * map_get(sample_interval_ms,D) * 1000000 -> holdover;
                follower when map_get(last_error,D) =/= undefined -> holdover;
                follower when map_get(filter_ready,D) =:= false -> acquiring;
                follower when Age =< 2 * map_get(sample_interval_ms, D) * 1000000,
                              map_get(confirmed,D) =:= true,
                              map_get(last_error, D) =:= undefined -> synchronized;
                _ -> holdover
            end,
            (maps:without([mapping, master_pid], D))#{state => State, age_ns => Age,
                filtered_utc_time => parvi_clock_mapping:from_monotonic(Mapping,T),
                offset_ns => parvi_clock_mapping:offset(Mapping, T),
                remaining_correction_ns => parvi_clock_mapping:remaining(Mapping, T),
                external_age_ns => age(maps:get(external_sync, D), T),
                %% Oscillator accuracy is unmeasured; old uncertainty is not
                %% misrepresented as current absolute accuracy during holdover.
                uncertainty_ns => unknown, holdover_drift_ppm => unknown,
                requests_served => metric(1), service_time_ns => metric(2)};
        #{role := Role} = D ->
            (maps:without([mapping, master_pid], D))#{state => case Role of
                waiting -> waiting_for_cluster; _ -> unsynchronized end};
        undefined -> #{state => stopped}
    end.

mapping() ->
    case snapshot() of
        #{mapping := M, role := Role} when is_map(M), Role =/= waiting -> {ok, M};
        _ -> {error, maps:get(state, status())}
    end.
snapshot() ->
    try ets:lookup(?MODULE, clock) of [{clock, D}] -> D; [] -> undefined
    catch error:badarg -> undefined end.

%% Legacy explicit-node API. New peers use scope- and process-bound requests.
reference_sample() ->
    case sample(any, any, false) of
        {ok, #{received_ns := T2, sent_ns := T3, uncertainty_ns := U}} -> {ok, T2, T3, U};
        Error -> Error
    end.
peer_sample(Scope, MasterPid) -> sample(Scope, MasterPid, true).
seed_sample(Scope) -> sample(Scope, any, false).

sample(Scope, Expected, RequireMaster) ->
    T2 = mono(),
    case snapshot() of
        #{scope := Current, role := Role, master_pid := MasterPid, mapping := M} = D
                when is_map(M), Role =/= waiting ->
            case (Scope =:= any orelse Scope =:= Current) andalso
                 (not RequireMaster orelse (Role =:= master andalso MasterPid =:= Expected
                                           andalso whereis(?MODULE) =:= Expected)) of
                false -> {error, reference_changed};
                true ->
                    T3 = mono(),
                    [{metrics, Counters}] = ets:lookup(?MODULE, metrics),
                    counters:add(Counters, 1, 1), counters:add(Counters, 2, T3 - T2),
                    {ok, #{received_ns => parvi_clock_mapping:from_monotonic(M, T2),
                           sent_ns => parvi_clock_mapping:from_monotonic(M, T3),
                           uncertainty_ns => unknown, scope => Current,
                           timeline => maps:get(timeline, D),
                           instance => maps:get(instance, D), revision => maps:get(revision,D),
                           service_ns => T3 - T2}}
            end;
        _ -> {error, reference_not_ready}
    end.

init([]) ->
    process_flag(trap_exit, true),
    ets:new(?MODULE, [named_table, protected, {read_concurrency, true}]),
    ets:insert(?MODULE, {metrics, counters:new(2, [write_concurrency])}),
    Interval = application:get_env(parvi, clock_interval_ms, ?CHECK_MS),
    SampleInterval = application:get_env(parvi, clock_sample_interval_ms, ?SAMPLE_MS),
    FilterSamples = application:get_env(parvi, clock_filter_samples, ?FILTER_SAMPLES),
    true = is_integer(SampleInterval) andalso SampleInterval > 0,
    true = is_integer(FilterSamples) andalso FilterSamples > 0,
    PPM = application:get_env(parvi, clock_slew_ppm, 500),
    DiscoveryWait = application:get_env(parvi, clock_peer_discovery_ms, 5000),
    true = is_integer(Interval) andalso Interval > 0,
    true = is_integer(PPM) andalso PPM > 0 andalso PPM < 1000000,
    true = is_integer(DiscoveryWait) andalso DiscoveryWait >= 0,
    Mode = application:get_env(parvi, clock_reference, auto), true = valid_reference(Mode),
    Upstream = application:get_env(parvi, clock_upstream, {ntp, "ntp.metas.ch"}),
    true = valid_upstream(Upstream),
    ok = net_kernel:monitor_nodes(true),
    Born = erlang:monotonic_time(millisecond),
    D = #{clock => id(), role => waiting, master => undefined, master_pid => undefined,
          scope => undefined, reference => undefined, coverage => unknown,
          instance => binary:encode_hex(crypto:strong_rand_bytes(16)), timeline => undefined,
          master_instance => undefined, master_revision => undefined,
          mapping => undefined, last_sync => undefined, external_sync => undefined,
          confirmed => false, coordination => connected_peers, upstream_acquisitions => 0,
          measurement_uncertainty_ns => unknown, revision => 0, last_error => undefined,
          interval_ms => Interval, sample_interval_ms => SampleInterval,
          filter_required_samples => FilterSamples, filter_sample_count => 0,
          filter_ready => false, filtered_offset_ns => undefined, threshold_ns => ?THRESHOLD_NS,
          slew_ppm => PPM, visible_clocks => 0},
    S = #{mode => Mode, upstream => Upstream, born => Born, interval => Interval,
          phase_timer => undefined, sample_timer => undefined,
          sample_interval => SampleInterval, filter => parvi_clock_filter:new(FilterSamples),
          filter_reference => undefined, retry_timer => undefined, pending => undefined,
          group => undefined, watch => undefined, next_external => undefined,
          peer_deadline => undefined, discovery_wait_ms => DiscoveryWait,
          backoff_ms => 30000, blocked => false, force => false, clock => D},
    self() ! sync,
    {ok, arm_sample(arm_phase(save(S, D)))}.

handle_call({reference, Reference}, _, S) ->
    case valid_reference(Reference) of
        true ->
            application:set_env(parvi, clock_reference, Reference),
            Refresh = case Reference of auto -> false; {node,_} -> false; _ -> true end,
            Due = case Refresh of true -> undefined; false -> maps:get(next_external,S) end,
            self() ! sync,
            {reply, ok, cancel(S#{mode := Reference, blocked := false, force := Refresh, next_external := Due})};
        false -> {reply, {error, invalid_reference}, S}
    end;
handle_call(resync, _, S) ->
    self() ! sync,
    {reply, ok, cancel(S#{blocked := false, force := true})};
handle_call(_, _, S) -> {reply, {error, unsupported_request}, S}.
handle_cast(_, S) -> {noreply, S}.

handle_info(tick, S) -> {noreply, check_correction(arm_phase(select(S)))};
handle_info(sample, S) -> {noreply, sync(arm_sample(S))};
handle_info(sync, S) -> {noreply, sync(S)};
handle_info(retry, S) -> {noreply, sync(S#{retry_timer := undefined})};
handle_info(membership_changed, S) -> {noreply, topology(S)};
handle_info({nodeup, _}, S) -> {noreply, topology(S)};
handle_info({nodedown, _}, S) -> {noreply, topology(S)};
handle_info({Watch, Event, _, _}, #{watch := Watch} = S) when Event =:= join; Event =:= leave ->
    {noreply, topology(S)};
handle_info({upstream, Pid, Result}, #{pending := #{kind := upstream, pid := Pid}} = S) ->
    {noreply, finish_upstream(Result, clear_pending(S))};
handle_info({request_timeout, Tag}, #{pending := #{tag := Tag} = Pending} = S) ->
    Clean = cancel(S),
    Next = case maps:get(kind,Pending) of
        upstream -> finish_upstream({error,request_timeout},Clean);
        seed -> seed(maps:get(remaining,Pending),Clean);
        _ -> retry(min(1000,maps:get(interval,S)),failed(request_timeout,Clean))
    end,
    {noreply, Next};
handle_info({'EXIT', Pid, Reason}, #{pending := #{kind := upstream, pid := Pid}} = S) ->
    {noreply, failed({sampler_exit, Reason}, cancel(S))};
handle_info(Message, #{pending := #{kind := Kind, request := Request} = Pending} = S)
        when Kind =:= peer; Kind =:= seed; Kind =:= manual_peer ->
    Response = try erpc:check_response(Message, Request) catch C:R -> {response, {error, {C,R}}} end,
    case Response of
        no_response -> {noreply, S};
        {response, Result} ->
            T4 = mono(),
            {noreply, finish_peer(Result, T4, Pending, clear_pending(S))}
    end;
handle_info(_, S) -> {noreply, S}.

topology(S) ->
    Next = select(S),
    OldD = maps:get(clock,S), NewD = maps:get(clock,Next),
    NewSeedPeer = maps:get(mapping,OldD) =:= undefined andalso
        maps:get(visible_clocks,NewD) > maps:get(visible_clocks,OldD),
    case selection(Next) =:= selection(S) andalso not NewSeedPeer of
        true -> Next;
        false -> self() ! sync, Next
    end.

selection(#{clock := D}) ->
    {maps:get(role,D), maps:get(master_pid,D), maps:get(scope,D), maps:get(master,D)}.

sync(S0) ->
    S = select(S0), D = maps:get(clock, S),
    case {maps:get(pending, S), maps:get(role, D)} of
        {undefined, master} ->
            case maps:get(mapping, D) =:= undefined orelse maps:get(force, S) of
                false -> S;
                true ->
                    Peers = case maps:get(mode, S) =:= auto andalso not maps:get(force, S) of
                        true -> [P || P <- pg:get_members(parvi_pg, maps:get(group, S)), P =/= self()];
                        false -> []
                    end,
                    seed(lists:usort(Peers), S)
            end;
        {undefined, follower} ->
            case maps:get(mode, S) of
                {node, Node} -> request(manual_peer, Node, reference_sample, [], [], S);
                _ -> request(peer, maps:get(master, D), peer_sample,
                             [maps:get(scope, D), maps:get(master_pid, D)], [], S)
            end;
        _ -> S
    end.

select(#{mode := auto} = S0) ->
    {Group, Expected} = context(), S = group(Group, S0),
    Peers = case Group of undefined -> []; _ -> lists:usort(pg:get_members(parvi_pg, Group)) end,
    Sorted = lists:sort([{atom_to_binary(node(P)), P} || P <- Peers]),
    {Role, Master, Pid} = case Sorted of
        [] -> {waiting, undefined, undefined};
        [{_, P} | _] when P =:= self() -> {master, node(), P};
        [{_, P} | _] -> {follower, node(P), P}
    end,
    Visible = [N || {N, _} <- Sorted],
    Coverage = case Expected of
        unknown -> unknown;
        _ -> case Expected -- Visible of [] -> complete; _ -> partial end
    end,
    choose(Role, Master, Pid, Group, Coverage, length(Peers), S);
select(#{mode := {node, Node}} = S0) ->
    S = group(undefined, S0), choose(follower, Node, undefined, {explicit, Node}, unknown, 0, S);
select(S0) ->
    S = group(undefined, S0), choose(master, node(), self(), {explicit, node()}, unknown, 1, S).

context() ->
    case application:get_env(parvi, native_desk, false) of
        true ->
            case parvi_cluster_trust:snapshot() of
                #{<<"cluster">> := Cluster, <<"epoch">> := Epoch, <<"members">> := Members} ->
                    {{parvi, clock, Cluster, Epoch}, lists:sort([maps:get(<<"node">>, M) || M <- maps:values(Members)])};
                undefined -> {undefined, []}
            end;
        false -> {{parvi, clock, local}, unknown}
    end.

group(Group, #{group := Group} = S) -> S;
group(Group, #{group := Old, watch := Watch} = S) ->
    case Old of undefined -> ok; _ -> pg:leave(parvi_pg, Old, self()), pg:demonitor(parvi_pg, Watch) end,
    case Group of
        undefined -> S#{group := undefined, watch := undefined, peer_deadline := undefined};
        _ ->
            {Ref, _} = pg:monitor(parvi_pg, Group), ok = pg:join(parvi_pg, Group, self()),
            S#{group := Group, watch := Ref,
               peer_deadline := erlang:monotonic_time(millisecond) + maps:get(discovery_wait_ms,S)}
    end.

choose(Role, Master, Pid, Scope, Coverage, Count, #{clock := D} = S) ->
    Changed = {Role, Pid, Scope, Master} =/=
        {maps:get(role,D), maps:get(master_pid,D), maps:get(scope,D), maps:get(master,D)},
    Next = case Changed of true -> clear_retry(cancel(S)); false -> S end,
    Confirmed = case Changed of true -> Role =:= master; false -> maps:get(confirmed,D) end,
    MasterInstance = case {Role,Changed} of
        {master,_} -> maps:get(instance,D);
        {_,true} -> undefined;
        _ -> maps:get(master_instance,D)
    end,
    Error = case Changed of true -> undefined; false -> maps:get(last_error,D) end,
    Reference = case Role of master -> {local, Master}; follower -> {node, Master}; waiting -> undefined end,
    Updated = save(Next, D#{role := Role, master := Master, master_pid := Pid, scope := Scope,
                  reference := Reference, coverage := Coverage, visible_clocks := Count,
                  confirmed := Confirmed, master_instance := MasterInstance, last_error := Error}),
    case Changed of true -> reset_filter(Updated); false -> Updated end.

seed([], S) -> upstream(S);
seed([Peer | Rest], #{clock := D} = S) ->
    request(seed, node(Peer), seed_sample, [maps:get(scope,D)], Rest, S).

request(Kind, Node, Function, Args, Rest, S) ->
    T1 = mono(), Tag = make_ref(),
    Request = erpc:send_request(Node, ?MODULE, Function, Args),
    Timer = erlang:send_after(4000, self(), {request_timeout, Tag}),
    S#{force := false, pending := #{kind => Kind, request => Request, tag => Tag,
                                   timer => Timer, sent => T1, remaining => Rest}}.

upstream(#{blocked := true} = S) -> S;
upstream(#{mode := auto, force := false, peer_deadline := Deadline,
           clock := #{coverage := partial, mapping := undefined}} = S) ->
    Now = erlang:monotonic_time(millisecond),
    case Now < Deadline of
        true -> retry(Deadline-Now,S);
        false -> acquire_upstream(S)
    end;
upstream(S) -> acquire_upstream(S).

acquire_upstream(#{next_external := Due} = S) ->
    Now = erlang:monotonic_time(millisecond),
    case Due =:= undefined orelse Now >= Due of
        false -> retry(Due - Now, S);
        true ->
            Source = case maps:get(mode,S) of auto -> maps:get(upstream,S); Other -> Other end,
            Owner = self(), Tag = make_ref(),
            Pid = spawn_link(fun() ->
                Result = try measure(Source) catch C:R -> {error, {C,R}} end,
                Owner ! {upstream, self(), Result}
            end),
            Timer = erlang:send_after(4000, self(), {request_timeout, Tag}),
            S#{force := false, pending := #{kind => upstream, pid => Pid, tag => Tag,
                                           timer => Timer}, next_external := Now + 15000}
    end.

finish_upstream({ok, Sample}, #{clock := D} = S) ->
    Timeline = case maps:get(timeline,D) of
        undefined -> maps:get(instance,D); Existing -> Existing
    end,
    Anchor = Sample#{timeline => Timeline},
    applied(Anchor, record_sample(Anchor,S#{backoff_ms := 30000}), true);
finish_upstream({error, Reason}, S) ->
    Backoff = min(600000, maps:get(backoff_ms,S) * 2),
    Blocked = case Reason of {kiss_of_death, _} -> true; _ -> false end,
    Next = failed(Reason, S#{blocked := Blocked, backoff_ms := Backoff,
                             next_external := erlang:monotonic_time(millisecond) + Backoff}),
    case Blocked of true -> Next; false -> retry(Backoff, Next) end.

finish_peer({ok, T2, T3, U}, T4, #{kind := manual_peer} = P, S) ->
    finish_peer({ok, #{received_ns => T2, sent_ns => T3, uncertainty_ns => U,
                       timeline => <<"explicit-peer">>}}, T4, P#{kind := peer}, S);
finish_peer({ok, #{received_ns := T2, sent_ns := T3, uncertainty_ns := U} = Reply}, T4,
            #{sent := T1}, S) ->
    case parvi_clock_sync:measure(T1,T2,T3,T4) of
        {error,Reason} -> failed(Reason,S);
        {ok,Measurement} ->
            Sample = Measurement#{uncertainty_ns => add_uncertainty(U,maps:get(round_trip_ns,Measurement) div 2),
                       timeline => maps:get(timeline,Reply),
                       master_instance => maps:get(instance,Reply,unknown),
                       master_revision => maps:get(revision,Reply,unknown)},
            applied(Sample, record_sample(Sample,S), false)
    end;
finish_peer(_, _, #{kind := seed, remaining := Rest}, S) -> seed(Rest, S);
finish_peer(Error, _, _, S) -> failed(Error, S).

reset_filter(#{clock := D} = S) ->
    save((maps:remove(last_sample_slot,S))#{filter := parvi_clock_filter:new(maps:get(filter_required_samples,D)),
            filter_reference := undefined},
         D#{filter_sample_count := 0,filter_ready := false,filtered_offset_ns := undefined}).

record_sample(Sample, S0) ->
    Ref = {maps:get(timeline,Sample),maps:get(master_instance,Sample,unknown)},
    D0 = maps:get(clock,S0),
    Stale = case maps:get(last_sync,D0) of
        undefined -> false;
        Last -> maps:get(sampled_at,Sample)-Last > 2*maps:get(sample_interval_ms,D0)*1000000
    end,
    S = case maps:get(filter_reference,S0) =:= Ref andalso not Stale of
        true -> S0; false -> reset_filter(S0)
    end,
    #{clock := D,filter := Filter} = S,
    %% Topology events and explicit resync can request an extra observation.
    %% Count at most one measurement per local sampling period.
    Slot = (maps:get(sampled_at,Sample) div 1000000-maps:get(born,S)) div maps:get(sample_interval,S),
    Next = case maps:get(last_sample_slot,S,undefined) of
        Slot -> Filter;
        _ -> parvi_clock_filter:add(Sample,Filter)
    end,
    Estimate = parvi_clock_filter:estimate(Next),
    Target = case Estimate of {ok,Offset} -> Offset; _ -> undefined end,
    save(S#{filter := Next,filter_reference := Ref,last_sample_slot => Slot},
         D#{filter_sample_count := parvi_clock_filter:count(Next),
            filter_ready := element(1,Estimate) =:= ok,filtered_offset_ns := Target}).

check_correction(#{clock := #{role := follower,filter_ready := true,
                            filtered_offset_ns := Target,last_sync := Last} = D} = S) ->
    T = mono(),
    %% An old window is not permission to correct after losing the master.
    case T-Last =< 2*maps:get(sample_interval_ms,D)*1000000 andalso maps:get(confirmed,D)
            andalso maps:get(last_error,D) =:= undefined of
        true -> save(S,correct_mapping(Target,T,D));
        false -> S
    end;
check_correction(S) -> S.

applied(#{offset_ns := Target, sampled_at := T, uncertainty_ns := U, timeline := Timeline} = Sample,
        #{clock := D} = S, External) ->
    Old = maps:get(mapping,D),
    %% Regular follower corrections happen only on the 30-second check timer.
    {Mapping,Correction,Adjust} = case Old =:= undefined orelse External of
        true -> parvi_clock_sync:correct(Old,T,Target,?THRESHOLD_NS,maps:get(slew_ppm,D));
        false -> {Old,0,false}
    end,
    Revision = maps:get(revision,D) + case Adjust of true -> 1; false -> 0 end,
    ExternalTime = case External of true -> T; false -> maps:get(external_sync,D) end,
    Acquisitions = maps:get(upstream_acquisitions,D) + case External of true -> 1; false -> 0 end,
    {MasterInstance,MasterRevision} = case maps:get(role,D) of
        master -> {maps:get(instance,D),Revision};
        _ -> {maps:get(master_instance,Sample,unknown),maps:get(master_revision,Sample,unknown)}
    end,
    NextD = (maps:merge(D,maps:with([round_trip_ns,stratum],Sample)))#{mapping := Mapping,
        last_sync := T, external_sync := ExternalTime, timeline := Timeline,
        measurement_uncertainty_ns := U, revision := Revision, last_error := undefined,
        confirmed := true, upstream_acquisitions := Acquisitions,
        master_instance := MasterInstance, master_revision := MasterRevision},
    Next = save(clear_retry(S),NextD),
    log_correction(Adjust,Correction,Revision,Old,NextD),
    Next.

correct_mapping(Target,T,#{mapping := Old,slew_ppm := PPM,revision := Revision} = D) ->
    {Mapping,Error,Adjusted} = parvi_clock_sync:correct(Old,T,Target,?THRESHOLD_NS,PPM),
    NextRevision = Revision + case Adjusted of true -> 1; false -> 0 end,
    Next = D#{mapping := Mapping,revision := NextRevision},
    log_correction(Adjusted,Error,NextRevision,Old,Next),
    Next.

log_correction(false,_,_,_,_) -> ok;
log_correction(true,Error,Revision,Old,D) ->
    Text = case Old of
        undefined -> <<"[Clock] Time acquired.">>;
        _ -> iolist_to_binary(io_lib:format("[Clock] Slew target: ~.3f ms.",[Error/1000000]))
    end,
    {ok,_} = parvi_chat:system(trace,clock_adjusted,Text,
        #{correction_ns => Error,revision => Revision,reference => maps:get(reference,D)}), ok.

failed(Reason, #{clock := D} = S) -> save(S,D#{last_error := Reason}).
save(S,D) ->
    Keys = [role,master,coverage,revision,filter_ready,last_error],
    case maps:with(Keys,maps:get(clock,S,#{})) =:= maps:with(Keys,D) of
        true -> ok; false -> parvi_events:notify(clock)
    end,
    ets:insert(?MODULE,{clock,D}), S#{clock := D}.
retry(Delay, #{retry_timer := undefined} = S) -> S#{retry_timer := erlang:send_after(Delay,self(),retry)};
retry(_,S) -> S.
clear_retry(#{retry_timer := undefined} = S) -> S;
clear_retry(#{retry_timer := Timer} = S) -> erlang:cancel_timer(Timer), S#{retry_timer := undefined}.
arm_phase(#{born := Born, interval := I} = S) ->
    Now = erlang:monotonic_time(millisecond), Due = Born + ((Now-Born) div I + 1)*I,
    S#{phase_timer := erlang:send_after(max(1,Due-Now),self(),tick)}.
arm_sample(#{born := Born,sample_interval := I} = S) ->
    Now = erlang:monotonic_time(millisecond), Due = Born + ((Now-Born) div I + 1)*I,
    S#{sample_timer := erlang:send_after(max(1,Due-Now),self(),sample)}.
clear_pending(#{pending := #{timer := Timer}} = S) -> erlang:cancel_timer(Timer), S#{pending := undefined}.
cancel(#{pending := undefined} = S) -> S;
cancel(#{pending := #{kind := upstream, pid := Pid}} = S) -> exit(Pid,shutdown), clear_pending(S);
cancel(#{pending := #{request := Request}} = S) ->
    try erpc:receive_response(Request,0) catch _:_ -> ok end, clear_pending(S).

measure({ntp,Host}) -> parvi_sntp:query(Host,123,2000);
measure({ntp,Host,Port}) -> parvi_sntp:query(Host,Port,2000);
measure(system) ->
    M1=mono(), T=erlang:system_time(nanosecond), M2=mono(),
    {ok,#{offset_ns => T-(M1+M2) div 2, sampled_at => M2,
          round_trip_ns => 0, uncertainty_ns => unknown}}.
valid_reference(auto) -> true;
valid_reference({node,Node}) -> is_atom(Node) andalso Node =/= node() andalso Node =/= nonode@nohost;
valid_reference(Other) -> valid_upstream(Other).
valid_upstream(system) -> true;
valid_upstream({ntp,Host}) -> valid_host(Host);
valid_upstream({ntp,Host,Port}) -> valid_host(Host) andalso is_integer(Port) andalso Port>0 andalso Port<65536;
valid_upstream(_) -> false.
valid_host(Host) -> is_list(Host) andalso Host=/=[] andalso
    lists:all(fun(C) -> is_integer(C) andalso C>0 andalso C<128 end,Host).
mono() -> erlang:monotonic_time(nanosecond).
age(undefined,_) -> undefined;
age(T,Now) -> max(0,Now-T).
add_uncertainty(unknown,_) -> unknown;
add_uncertainty(U,Extra) -> U+Extra.
metric(N) ->
    try ets:lookup(?MODULE,metrics) of [{metrics,C}] -> counters:get(C,N); [] -> 0
    catch error:badarg -> 0 end.
terminate(_,S) ->
    cancel(S),
    [case maps:get(K,S) of undefined -> ok; Timer -> erlang:cancel_timer(Timer) end
     || K <- [phase_timer,sample_timer,retry_timer]], ok.
