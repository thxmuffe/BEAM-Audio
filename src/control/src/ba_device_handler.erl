%% Local resource authority. No network ingress, arbitrary modules or hardware.
-module(ba_device_handler).
-behaviour(gen_server).
-export([start_link/0,capabilities/0,status/0,enable_test/1,start/2,cancel/1]).
-export([set_test_contract/3,clear_test_contract/0,accept_job/3,cancel_job/2,session_down/2]).
-export([init/1,handle_call/3,handle_cast/2,handle_info/2]).
-define(CAPACITY,2).
-define(HISTORY,16).

start_link() -> gen_server:start_link({local,?MODULE},?MODULE,[],[]).
capabilities() -> gen_server:call(?MODULE,capabilities,100).
status() -> gen_server:call(?MODULE,status).
enable_test(Enabled) -> gen_server:call(?MODULE,{enable_test,Enabled}).
start(Capability,Args) -> gen_server:call(?MODULE,{start,Capability,Args}).
cancel(Id) -> gen_server:call(?MODULE,{cancel,Id}).
set_test_contract(Director,Id,Revision) -> gen_server:call(?MODULE,{test_contract,Director,Id,Revision}).
clear_test_contract() -> gen_server:call(?MODULE,clear_test_contract).
accept_job(Context,Id,Offer) -> gen_server:call(?MODULE,{accept_job,Context,Id,Offer}).
cancel_job(Context,Id) -> gen_server:call(?MODULE,{cancel_job,Context,Id}).
session_down(Peer,Session) -> gen_server:call(?MODULE,{session_down,Peer,Session}).
init([]) ->
    {ok,#{instance => fresh(),revision => 0,enabled => false,active => #{},history => [],
          contract => undefined,jobs => #{},control => undefined,control_monitor => undefined}}.

handle_call(capabilities,_,S) -> {reply,capability_snapshot(S),S};
handle_call(status,_,S) ->
    {reply,#{capabilities => capability_snapshot(S),active =>
        maps:map(fun(_,W) -> public(W) end,maps:get(active,S)),history => maps:get(history,S),
        jobs => maps:map(fun(_,J) -> maps:get(report,J) end,maps:get(jobs,S)),contract => maps:get(contract,S)},S};
handle_call({test_contract,Director,Id,Revision},_,S) ->
    case ba_swarm_job:hex(Director,64) andalso ba_swarm_job:hex(Id,32) andalso
         is_integer(Revision) andalso Revision > 0 andalso Revision =< 9007199254740991 of
        false -> {reply,{error,invalid_contract},S};
        true ->
            New = #{director => Director,id => Id,revision => Revision},
            case maps:get(contract,S) of
                New -> {reply,ok,S};
                #{id := Id,revision := Old} when Revision =< Old -> {reply,{error,stale_contract},S};
                _ -> {reply,ok,changed((stop_jobs(fun(_) -> true end,contract_revoked,S))#{contract := New})}
            end
    end;
handle_call(clear_test_contract,_,S) ->
    {reply,ok,changed((stop_jobs(fun(_) -> true end,contract_revoked,S))#{contract := undefined})};
handle_call({accept_job,Context,Id,Offer},{Caller,_},S) ->
    case Caller =:= whereis(ba_swarm_control) of
        true -> evaluate_job(Context,Id,Offer,watch_control(Caller,S));
        false -> {reply,{error,not_control},S}
    end;
handle_call({cancel_job,Context,Id},{Caller,_},S) ->
    case Caller =:= whereis(ba_swarm_control) of
        true -> cancel_network_job(Context,Id,watch_control(Caller,S));
        false -> {reply,{error,not_control},S}
    end;
handle_call({session_down,Peer,Session},{Caller,_},S) ->
    case Caller =:= whereis(ba_swarm_control) of
        true ->
            Match = fun(#{context := C}) -> maps:get(peer,C) =:= Peer andalso maps:get(session,C) =:= Session end,
            Next = stop_jobs(Match,session_lost,S),
            {reply,ok,Next#{jobs := maps:filter(fun(_,J) -> not Match(J) end,maps:get(jobs,Next))}};
        false -> {reply,{error,not_control},S}
    end;
handle_call({enable_test,Enabled},_,S) when is_boolean(Enabled) ->
    Next = case Enabled of
        true -> S;
        false -> lists:foldl(fun(Id,Acc) -> stop(Id,consent_revoked,Acc) end,
                            S,maps:keys(maps:get(active,S)))
    end,
    {reply,ok,changed(Next#{enabled := Enabled})};
handle_call({start,test,#{duration_ms := Duration} = Args},_,S)
        when map_size(Args) =:= 1,is_integer(Duration),Duration >= 20,Duration =< 10000 ->
    case {maps:get(enabled,S),map_size(maps:get(active,S)) < ?CAPACITY} of
        {false,_} -> {reply,{error,consent_required},S};
        {true,false} -> {reply,{error,capacity_exceeded},S};
        {true,true} -> start_test(Duration,S)
    end;
handle_call({start,_,_},_,S) -> {reply,{error,unsupported_capability_or_arguments},S};
handle_call({cancel,Id},_,#{active := Active,history := History} = S) ->
    case maps:is_key(Id,Active) orelse lists:any(fun(#{id := N}) -> N =:= Id end,History) of
        true -> {reply,ok,stop(Id,cancelled,S)};
        false -> {reply,{error,unknown_worker},S}
    end;
handle_call(_,_,S) -> {reply,{error,unsupported},S}.
handle_cast(_,S) -> {noreply,S}.

handle_info({'DOWN',Ref,process,_,_},#{control_monitor := Ref} = S) ->
    Next = stop_jobs(fun(_) -> true end,session_lost,S),
    {noreply,Next#{jobs := #{},control := undefined,control_monitor := undefined}};
handle_info({job_expire,Id,Attempt},#{jobs := Jobs} = S) ->
    case maps:find(Id,Jobs) of
        {ok,#{worker := Worker,report := #{<<"state">> := <<"accepted">>,<<"attempt">> := Attempt}}} ->
            {noreply,stop(Worker,expired,S)};
        _ -> {noreply,S}
    end;
handle_info({worker_event,Pid,Id,Attempt,Event},#{active := Active} = S) ->
    case maps:find(Id,Active) of
        {ok,#{pid := Pid,attempt := Attempt,state := State} = W} ->
            case {State,Event} of
                {starting,ready} -> {noreply,changed(S#{active := Active#{Id := W#{state := running}}})};
                {running,completed} ->
                    %% Capacity is not released until the actual process DOWN.
                    {noreply,S#{active := Active#{Id := W#{state := completed}}}};
                _ -> {noreply,S}
            end;
        _ -> {noreply,S}
    end;
handle_info({'DOWN',Ref,process,Pid,_Reason},#{active := Active} = S) ->
    case [Id || {Id,#{pid := P,monitor := R}} <- maps:to_list(Active),P =:= Pid,R =:= Ref] of
        [Id] ->
            Outcome = case maps:get(state,maps:get(Id,Active)) of
                completed -> completed;
                _ -> failed
            end,
            {noreply,finish(Id,Outcome,S)};
        [] -> {noreply,S}
    end;
handle_info(_,S) -> {noreply,S}.

start_test(Duration,#{active := Active} = S) ->
    Id = fresh(), Attempt = fresh(),
    Spec = #{owner => self(),id => Id,attempt => Attempt,duration_ms => Duration},
    Result = try supervisor:start_child(ba_device_worker_sup,
        #{id => Id,start => {ba_device_test_worker,start_link,[Spec]},
          restart => temporary,shutdown => 1000})
        catch exit:_ -> {error,worker_supervisor_unavailable} end,
    case Result of
        {ok,Pid} ->
            W = #{id => Id,attempt => Attempt,pid => Pid,monitor => monitor(process,Pid),state => starting},
            {reply,{ok,Id},changed(S#{active := Active#{Id => W}})};
        _ -> {reply,{error,worker_supervisor_unavailable},S}
    end.
stop(Id,Outcome,#{active := Active} = S) ->
    case maps:find(Id,Active) of
        error -> S;
        {ok,#{monitor := Ref}} ->
            %% The supervisor waits for shutdown before returning the slot.
            case supervisor:terminate_child(ba_device_worker_sup,Id) of
                ok -> ok;
                {error,not_found} -> ok
            end,
            demonitor(Ref,[flush]), finish(Id,Outcome,S)
    end.
finish(Id,Outcome,#{active := Active,history := History} = S) ->
    {W,Rest} = maps:take(Id,Active),
    {Final,Next} = finish_job(W,Outcome,S),
    changed(Next#{active := Rest,history := lists:sublist([(public(W))#{state := Final}|History],?HISTORY)}).
public(W) -> maps:with([id,attempt,state],W).
changed(S) -> S#{revision := maps:get(revision,S)+1}.
capability_snapshot(#{active := Active,enabled := Enabled,instance := Instance,revision := Revision}) ->
    Count = map_size(Active),
    #{<<"instance">> => Instance,<<"revision">> => Revision,<<"test">> => #{
        <<"supported">> => true,<<"available">> => Enabled andalso Count < ?CAPACITY andalso
            is_pid(whereis(ba_device_worker_sup)),
        <<"requires_consent">> => true,<<"consent">> => Enabled,
        <<"capacity">> => ?CAPACITY,<<"active">> => Count,<<"max_duration_ms">> => 10000}}.
fresh() -> binary:encode_hex(crypto:strong_rand_bytes(16)).

watch_control(Pid,#{control := undefined} = S) ->
    S#{control := Pid,control_monitor := monitor(process,Pid)};
watch_control(Pid,#{control := Pid} = S) -> S;
watch_control(Pid,S) ->
    Next = stop_jobs(fun(_) -> true end,session_lost,S),
    demonitor(maps:get(control_monitor,S),[flush]),
    Next#{jobs := #{},control := Pid,control_monitor := monitor(process,Pid)}.

evaluate_job(Context,Id,Offer,#{jobs := Jobs} = S) ->
    case maps:find(Id,Jobs) of
        {ok,#{context := Old,offer := Offer}} ->
            case same_context(Old,Context) of
                true ->
                    Next = expire_job(Id,S),
                    {reply,{ok,maps:get(report,maps:get(Id,maps:get(jobs,Next)))},Next};
                false -> {reply,{ok,rejected(conflicting_offer)},S}
            end;
        {ok,_} -> {reply,{ok,rejected(conflicting_offer)},S};
        error when map_size(Jobs) >= 32 -> {reply,{ok,rejected(job_limit)},S};
        error ->
            Reason = job_permission(Context,Offer,S),
            case Reason of
                ok -> accept_test_job(Context,Id,Offer,S);
                _ ->
                    Report = rejected(Reason),
                    J = #{context => Context,offer => Offer,report => Report},
                    {reply,{ok,Report},S#{jobs := Jobs#{Id => J}}}
            end
    end.
job_permission(#{peer := Peer,director := Peer,deadline := Deadline},Offer,S) ->
    try
        ok = ba_swarm_job:validate_offer(Offer),
        true = erlang:monotonic_time(millisecond) < Deadline,
        #{director := Peer,id := Contract,revision := Revision} = maps:get(contract,S),
        Contract = maps:get(<<"contract">>,Offer), Revision = maps:get(<<"contract_revision">>,Offer),
        case {maps:get(enabled,S),map_size(maps:get(active,S)) < ?CAPACITY} of
            {false,_} -> consent_required;
            {true,false} -> capacity_exceeded;
            _ -> ok
        end
    catch _:_ -> contract_mismatch end;
job_permission(_,_,_) -> contract_mismatch.
accept_test_job(Context,Id,Offer,S) ->
    Now = erlang:monotonic_time(millisecond),
    Deadline = min(maps:get(deadline,Context),Now+maps:get(<<"lease_ms">>,Offer)),
    case start_test(maps:get(<<"duration_ms">>,Offer),S) of
        {reply,{ok,Worker},#{active := Active,jobs := Jobs} = Next} ->
            W = maps:get(Worker,Active), Attempt = maps:get(attempt,W),
            Report = ba_swarm_job:report(Attempt,<<"accepted">>,<<"none">>),
            Timer = erlang:send_after(max(0,Deadline-erlang:monotonic_time(millisecond)),self(),{job_expire,Id,Attempt}),
            J = #{context => Context,offer => Offer,report => Report,worker => Worker,deadline => Deadline,timer => Timer},
            {reply,{ok,Report},Next#{active := Active#{Worker := W#{job => Id}},jobs := Jobs#{Id => J}}};
        {reply,_,_} -> {reply,{ok,rejected(handler_unavailable)},S}
    end.
cancel_network_job(Context,Id,#{jobs := Jobs} = S) ->
    case maps:find(Id,Jobs) of
        {ok,#{context := Old} = J} ->
            case same_context(Old,Context) of
                false -> {reply,{ok,rejected(conflicting_offer)},S};
                true ->
                    Next = case maps:get(<<"state">>,maps:get(report,J)) of
                        <<"accepted">> -> stop(maps:get(worker,J),cancelled,S);
                        _ -> S
                    end,
                    {reply,{ok,maps:get(report,maps:get(Id,maps:get(jobs,Next)))},Next}
            end;
        error when map_size(Jobs) >= 32 -> {reply,{ok,rejected(job_limit)},S};
        error ->
            Report = ba_swarm_job:report(null,<<"cancelled">>,<<"cancelled">>),
            {reply,{ok,Report},S#{jobs := Jobs#{Id => #{context => Context,report => Report}}}}
    end.
expire_job(Id,#{jobs := Jobs} = S) ->
    case maps:get(Id,Jobs) of
        #{worker := Worker,deadline := Deadline,report := #{<<"state">> := <<"accepted">>}} ->
            case erlang:monotonic_time(millisecond) >= Deadline of true -> stop(Worker,expired,S); false -> S end;
        _ -> S
    end.
stop_jobs(Predicate,Outcome,#{jobs := Jobs} = S) ->
    lists:foldl(fun({_,J},Acc) ->
        case {Predicate(J),maps:get(<<"state">>,maps:get(report,J))} of
            {true,<<"accepted">>} -> stop(maps:get(worker,J),Outcome,Acc);
            _ -> Acc
        end
    end,S,maps:to_list(Jobs)).
finish_job(#{job := Id,attempt := Attempt},Outcome,#{jobs := Jobs,control := Control} = S) ->
    J = maps:get(Id,Jobs), erlang:cancel_timer(maps:get(timer,J)),
    Final = case erlang:monotonic_time(millisecond) >= maps:get(deadline,J) of
        true -> expired; false -> Outcome end,
    {State,Reason} = case Final of
        completed -> {<<"completed">>,<<"none">>};
        failed -> {<<"failed">>,<<"worker_failed">>};
        expired -> {<<"expired">>,<<"lease_expired">>};
        cancelled -> {<<"cancelled">>,<<"cancelled">>};
        consent_revoked -> {<<"cancelled">>,<<"consent_revoked">>};
        contract_revoked -> {<<"cancelled">>,<<"contract_revoked">>};
        session_lost -> {<<"cancelled">>,<<"session_lost">>}
    end,
    Report = ba_swarm_job:report(Attempt,State,Reason),
    Control ! {job_report,self(),maps:get(context,J),Id,Report},
    {Final,S#{jobs := Jobs#{Id := (maps:without([timer,worker],J))#{report := Report}}}};
finish_job(_,Outcome,S) -> {Outcome,S}.
same_context(A,B) -> maps:with([peer,session,swarm],A) =:= maps:with([peer,session,swarm],B).
rejected(Reason) -> ba_swarm_job:report(null,<<"rejected">>,atom_to_binary(Reason)).
