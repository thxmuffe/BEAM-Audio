%% Local clock/Offset owner. Cross-device work uses scoped signed Swarm messages.
-module(ba_swarm_clock).
-behaviour(gen_server).
-compile({no_auto_import,[now/0]}).
-export([start_link/0,id/0,now/0,filtered_utc_time/0,from_monotonic/1,to_monotonic/1,map_times/1,
         presentation/1,status/0,set_reference/1,resync/0,offset/0,offset_status/0,set_offset/1,set_offset/2,
         reference_sample/0,peer_sample/2,seed_sample/1]).
-export([init/1,handle_call/3,handle_cast/2,handle_info/2,terminate/2,format_status/1]).
start_link() -> gen_server:start_link({local,?MODULE},?MODULE,[],[]).
id() -> maps:get(timeline,snapshot(),undefined).
now() -> from_monotonic(mono()).
filtered_utc_time() -> now().
from_monotonic(T) -> case map_times([T]) of {ok,[U]} -> {ok,U};Error -> Error end.
map_times(Times) ->
    D = snapshot(),case ready(D) of
        true -> M = maps:get(mapping,D),{ok,[ba_swarm_clock_mapping:from_monotonic(M,T) || T <- Times]};
        false -> {error,clock_unavailable}
    end.
to_monotonic(T) ->
    D = snapshot(),case ready(D) of
        true -> {ok,ba_swarm_clock_mapping:to_monotonic(maps:get(mapping,D),T)};
        false -> {error,clock_unavailable}
    end.
presentation(Times) ->
    D = snapshot(),case ready(D) andalso offset_ready(D) of
        true ->
            P = maps:get(offset,D),M = maps:get(mapping,D),
            {ok,#{clock => maps:get(timeline,D),offset_ms => maps:get(<<"offset_ms">>,P),
                  offset_revision => maps:get(<<"revision">>,P),
                  times => [ba_swarm_clock_mapping:from_monotonic(M,T) || T <- Times]}};
        false -> {error,clock_or_offset_unavailable}
    end.
offset() -> D = snapshot(),case offset_ready(D) of
    true -> {ok,maps:get(<<"offset_ms">>,maps:get(offset,D))};false -> {error,offset_unavailable} end.
offset_status() -> offset_view(snapshot()).
set_offset(Value) -> gen_server:call(?MODULE,{offset,Value,current},6000).
set_offset(Value,Revision) -> gen_server:call(?MODULE,{offset,Value,Revision},6000).
set_reference(Mode) -> gen_server:call(?MODULE,{reference,Mode}).
resync() -> gen_server:call(?MODULE,resync).
reference_sample() -> {error,use_authenticated_swarm_control}.
peer_sample(_,_) -> {error,use_authenticated_swarm_control}.
seed_sample(_) -> {error,use_authenticated_swarm_control}.
status() ->
    D = snapshot(),Base = maps:without([mapping,offset,offset_until,authorization_until],D),
    M = maps:get(mapping,D,undefined),Now = mono(),
    State = case {ready(D),maps:get(role,D,waiting),M} of
        {true,_,_} -> synchronized;
        {false,waiting,_} -> waiting_for_membership;
        {false,_,undefined} -> acquiring;
        _ -> holdover
    end,
    Extra = case M of undefined -> #{};_ ->
        #{filtered_utc_time => ba_swarm_clock_mapping:from_monotonic(M,Now),
          offset_ns => ba_swarm_clock_mapping:offset(M,Now),remaining_correction_ns => ba_swarm_clock_mapping:remaining(M,Now)} end,
    (maps:merge(Base,Extra))#{state => State,age_ns => age(maps:get(last_sync,D,undefined),Now),
        offset_policy => offset_view(D),uncertainty_ns => unknown,holdover_drift_ppm => unknown}.
snapshot() -> try ets:lookup(?MODULE,clock) of [{clock,D}] -> D;_ -> #{} catch error:badarg -> #{} end.
ready(#{role := Role,mapping := M,confirmed := true,authorization_until := Until,last_sync := Last,
        filter_ready := Filter,sample_interval_ms := I}=D) when is_map(M),is_integer(Last) ->
    live(Until) andalso (Role=:=master orelse (Role=:=follower andalso Filter andalso
        live(maps:get(sample_authorization_until,D,undefined)) andalso mono()-Last=<2*I*1000000));
ready(_) -> false.
offset_ready(#{offset := P,offset_until := Until,authorization_until := Auth}) ->
    is_map(P) andalso live(Until) andalso live(Auth);
offset_ready(_) -> false.
offset_view(D) ->
    P = case maps:get(offset,D,undefined) of undefined -> #{};Value -> Value end,
    #{revision => maps:get(<<"revision">>,P,null),offset_ms => maps:get(<<"offset_ms">>,P,null),ready => offset_ready(D)}.

init([]) ->
    ets:new(?MODULE,[named_table,protected,{read_concurrency,true}]),
    Interval = application:get_env(ba_core,clock_sample_interval_ms,5000),
    Count = application:get_env(ba_core,clock_filter_samples,20),
    Phase = application:get_env(ba_core,clock_interval_ms,30000),PPM = application:get_env(ba_core,clock_slew_ppm,500),
    true = is_integer(Interval) andalso Interval>=10 andalso Interval=<60000,
    true = is_integer(Count) andalso Count>0 andalso Count=<128,
    true = is_integer(Phase) andalso Phase>=10 andalso Phase=<600000,
    true = is_integer(PPM) andalso PPM>0 andalso PPM<1000000,
    Mode = application:get_env(ba_core,clock_reference,application:get_env(ba_core,clock_upstream,{ntp,"ntp.metas.ch"})),
    Reference = case Mode of auto -> application:get_env(ba_core,clock_upstream,{ntp,"ntp.metas.ch"});_ -> Mode end,
    true = valid_reference(Reference),
    D = #{role => waiting,mapping => undefined,timeline => undefined,instance => fresh(),
        master_instance => undefined,master => undefined,reference_revision => 0,revision => 0,
        last_sync => undefined,confirmed => false,filter_ready => false,filter_sample_count => 0,
        filter_required_samples => Count,sample_interval_ms => Interval,interval_ms => Phase,
        threshold_ns => 2000000,slew_ppm => PPM,measurement_uncertainty_ns => unknown,
        last_error => null,offset_error => null,rejected => 0,upstream_acquisitions => 0,
        offset => undefined,offset_until => undefined,authorization_until => undefined},
    S = #{clock => D,scope => undefined,role => waiting,view => undefined,reference => Reference,
        pending => #{},upstream => undefined,blocked => false,last_external_start => undefined,next_external => now_ms(),backoff_ms => 30000,
        filter => ba_swarm_clock_filter:new(Count),filter_reference => undefined,
        born => now_ms(),filter_last_slot => undefined,sample_due => now_ms(),offset_due => now_ms(),connect_due => now_ms(),phase_due => now_ms()+Phase},
    erlang:send_after(100,self(),tick),{ok,save(S)}.
handle_call({offset,Value,Expected},From,S) when is_integer(Value),Value>=5,Value=<30000 ->
    case {maps:get(role,S),revision(Expected,S)} of
        {waiting,_} -> {reply,{error,membership_unavailable},S};
        {_,{error,R}} -> {reply,{error,R},S};
        {authority,Revision} ->
            {Result,Next} = commit(Value,Revision,S),{reply,Result,save(Next)};
        {member,Revision} ->
            P = #{<<"kind">> => <<"offset.set">>,<<"revision">> => Revision,<<"offset_ms">> => Value},
            case request(P,#{caller => From},S) of
                {ok,Next} -> {noreply,save(Next)};
                {error,R} -> {reply,{error,R},S}
            end
    end;
handle_call({reference,Mode},_,#{role := authority} = S) ->
    R = case Mode of auto -> application:get_env(ba_core,clock_upstream,{ntp,"ntp.metas.ch"});_ -> Mode end,
    case valid_reference(R) of
        false -> {reply,{error,invalid_reference},S};
        true ->
            D = maps:get(clock,S),
            case R=:=maps:get(reference,S) of
                true -> {reply,ok,save(S)};
                false ->
                    application:set_env(ba_core,clock_reference,R),
                    Next = cancel_upstream(S),
                    {reply,ok,save(Next#{reference := R,blocked := false,next_external := now_ms(),
                        clock := D#{instance := fresh(),timeline := undefined,mapping := undefined,
                                    reference_revision := 0,confirmed := false}})}
            end
    end;
handle_call({reference,_},_,S) -> {reply,{error,authority_reference_only},S};
handle_call(resync,_,#{role := authority} = S) ->
    Due = case {maps:get(reference,S),maps:get(last_external_start,S)} of
        {system,_} -> now_ms();{_,undefined} -> now_ms();{_,Started} -> max(now_ms(),Started+15000)
    end,
    D = maps:get(clock,S),
    {reply,ok,save(S#{blocked := false,next_external := Due,clock := D#{confirmed := false}})};
handle_call(resync,_,S) ->
    {reply,ok,save(reset_filter(invalidate(S#{sample_due := now_ms(),offset_due := now_ms()})))};
handle_call(_,_,S) -> {reply,{error,invalid_request},S}.
handle_cast(_,S) -> {noreply,S}.
handle_info(tick,S0) ->
    erlang:send_after(100,self(),tick),S1 = membership(S0),S2 = expire(S1),
    S3 = case maps:get(role,S2) of
        authority -> upstream(S2);
        member -> follow(S2);
        waiting -> S2
    end,
    {noreply,save(correct(S3))};
handle_info({swarm_time,Context,Id,P},S) ->
    try
        #{peer := Peer,session := Session,swarm := Swarm,deadline := Deadline} = Context,
        {Swarm,_} = maps:get(scope,S),
        true = now_ms()<Deadline,{ok,#{session := Session}} = context(Peer),
        incoming(Context,Id,P,S)
    of Next -> {noreply,save(Next)}
    catch exit:{time_storage_failed,_}=Reason -> exit(Reason);
        error:conflicting_revision ->
            D = maps:get(clock,S),{noreply,save(S#{clock := D#{offset_until := undefined,offset_error := conflicting_revision}})};
        _:_ -> D = maps:get(clock,S),{noreply,save(S#{clock := D#{rejected := maps:get(rejected,D)+1}})}
    end;
handle_info({time_session_down,Peer,Session},#{scope := {_,Peer}} = S) ->
    _ = Session,{noreply,save(invalidate(S))};
handle_info({upstream_result,Pid,Result},#{upstream := #{pid := Pid,monitor := Ref}} = S) ->
    demonitor(Ref,[flush]),{noreply,save(apply_upstream(Result,S#{upstream := undefined}))};
handle_info({'DOWN',Ref,process,_,_},#{upstream := #{monitor := Ref}} = S) ->
    {noreply,save(upstream_failed(S#{upstream := undefined}))};
handle_info(_,S) -> {noreply,S}.

membership(S) ->
    View = try ba_swarm_membership:current() catch exit:_ -> {error,unavailable} end,
    case View of
        {ok,#{policy := #{swarm := Swarm,authority := Authority}} = V} ->
            {Pub,_} = ba_device_store:identity(),Role = case binary:encode_hex(Pub)=:=Authority of true -> authority;false -> member end,
            Scope = {Swarm,Authority},
            Next = case maps:get(scope,S)=:=Scope of true -> S;false -> scope(Scope,Role,S) end,
            D = maps:get(clock,Next),ClockRole = case Role of authority -> master;member -> follower end,
            Until = maps:get(until,V),OffsetUntil = case Role of authority -> infinity;member -> maps:get(offset_until,D) end,
            Next#{role := Role,view := V,clock := D#{role := ClockRole,master := Authority,
                authorization_until := Until,offset_until := OffsetUntil}};
        _ ->
            D = maps:get(clock,S),invalidate(S#{role := waiting,clock := D#{role := waiting,authorization_until := undefined}})
    end.
scope({Swarm,Authority}=Scope,Role,S) ->
    Name = case Role of authority -> swarm_time_policy;member -> swarm_time_cache end,
    Default = case Role of authority -> #{<<"revision">> => 1,<<"offset_ms">> => 1000};member -> undefined end,
    Saved = ba_device_store:load(Name,undefined),
    P = case Saved of #{swarm := Swarm,authority := Authority,policy := Policy} -> ba_swarm_time_protocol:state(Policy),Policy;_ -> Default end,
    case Role of authority -> checkpoint(Name,Scope,P);member -> ok end,
    Next = reset_filter(invalidate(S)),D = maps:get(clock,Next),
    Next#{scope := Scope,clock := D#{offset := P,offset_until := undefined}}.
follow(#{view := V} = S) ->
    case lists:member(<<"time_read">>,maps:get(local_permissions,V,[])) of
        false ->
            D = maps:get(clock,S),Pending = maps:filter(fun(_,P) -> maps:get(kind,P)=:= <<"offset.set">> end,maps:get(pending,S)),
            reset_filter(S#{pending := Pending,clock := D#{confirmed := false,offset_until := undefined}});
        true ->
            {_,Authority} = maps:get(scope,S),
            case context(Authority) of
                {ok,_} ->
                    A = periodic(<<"sample.request">>,sample_due,#{<<"t1">> => ns(mono())},S),
                    periodic(<<"offset.get">>,offset_due,#{},A);
                _ ->
                    Next = invalidate(S),
                    case now_ms()>=maps:get(connect_due,Next) of
                        true -> _ = ba_swarm_control:connect(Authority),Next#{connect_due := now_ms()+1000};
                        false -> Next
                    end
            end
    end.
periodic(Kind,Due,Extra,S) ->
    Busy = lists:any(fun(P) -> maps:get(kind,P)=:=Kind end,maps:values(maps:get(pending,S))),
    case now_ms()>=maps:get(Due,S) andalso not Busy of
        false -> S;
        true ->
            P = Extra#{<<"kind">> => Kind},
            Next = case request(P,#{},S) of {ok,N} -> N;_ -> S end,
            Next#{Due := now_ms()+maps:get(sample_interval_ms,maps:get(clock,S))}
    end.
request(P,Extra,#{scope := {_,Authority},pending := Pending} = S) when map_size(Pending)<32 ->
    case context(Authority) of
        {ok,#{deadline := Until}=Context} ->
            Id = fresh(),Sent = mono(),
            case send(Authority,Id,P) of
                ok ->
                    R = Extra#{kind => maps:get(<<"kind">>,P),context => Context,sent => Sent,
                        deadline => min(Until,now_ms()+4000),payload => P},
                    {ok,S#{pending := Pending#{Id => R}}};
                _ -> {error,transport_unavailable}
            end;
        _ -> {error,no_authorized_session}
    end;
request(_,_,_) -> {error,request_limit}.

incoming(Context,Id,#{<<"kind">> := <<"sample.request">>,<<"t1">> := T1},#{role := authority,clock := D}=S) ->
    case ready(D) of
        true ->
            T2 = maps:get(received_at_ns,Context),T3 = mono(),M = maps:get(mapping,D),
            P = #{<<"kind">> => <<"sample.reply">>,<<"t1">> => T1,
                <<"t2">> => ns(ba_swarm_clock_mapping:from_monotonic(M,T2)),<<"t3">> => ns(ba_swarm_clock_mapping:from_monotonic(M,T3)),
                <<"timeline">> => maps:get(timeline,D),<<"instance">> => maps:get(instance,D),
                <<"reference_revision">> => maps:get(reference_revision,D),<<"uncertainty_ns">> =>
                    case maps:get(measurement_uncertainty_ns,D) of unknown -> null;U -> ns(U) end},
            reply(Context,Id,P),S;
        false -> reply_error(Context,Id,<<"sample.request">>,<<"unavailable">>),S
    end;
incoming(Context,Id,#{<<"kind">> := <<"offset.get">>},#{role := authority}=S) ->
    reply(Context,Id,offset_payload(<<"offset.state">>,S)),S;
incoming(Context,Id,#{<<"kind">> := <<"offset.set">>,<<"revision">> := Revision,<<"offset_ms">> := Value},#{role := authority}=S) ->
    case commit(Value,Revision,S) of
        {ok,Next} -> reply(Context,Id,offset_payload(<<"offset.state">>,Next)),Next;
        {{error,conflict},_} -> reply_error(Context,Id,<<"offset.set">>,<<"conflict">>),S
    end;
incoming(#{peer := Authority}=Context,_,#{<<"kind">> := <<"offset.changed">>}=P,#{role := member,scope := {_,Authority}}=S) ->
    adopt(P,min(maps:get(deadline,Context),now_ms()+freshness(S)),S);
incoming(#{peer := Authority,session := Session}=Context,Id,P,#{role := member,scope := {_,Authority},pending := Pending}=S) ->
    #{context := #{session := Session},deadline := Deadline,kind := Kind}=R = maps:get(Id,Pending),true = now_ms()<Deadline,
    Clean = S#{pending := maps:remove(Id,Pending)},Until = min(maps:get(deadline,Context),mono_ms(maps:get(sent,R))+freshness(S)),
    case maps:get(<<"kind">>,P) of
        <<"sample.reply">> ->
            <<"sample.request">> = Kind,
            Echo = maps:get(<<"t1">>,maps:get(payload,R)),Echo = maps:get(<<"t1">>,P),
            apply_sample(P,maps:get(received_at_ns,Context),Until,Clean);
        <<"offset.state">> ->
            true = Kind=:= <<"offset.get">> orelse Kind=:= <<"offset.set">>,
            Next = adopt(P,Until,Clean),answer(R,ok),Next;
        <<"error">> ->
            Kind = maps:get(<<"operation">>,P),Reason = maps:get(<<"reason">>,P),answer(R,{error,Reason}),
            case Kind of <<"sample.request">> -> fail(Reason,Clean);_ -> Clean end
    end;
incoming(Context,Id,#{<<"kind">> := Kind},S)
        when Kind=:= <<"sample.request">>;Kind=:= <<"offset.get">>;Kind=:= <<"offset.set">> ->
    reply_error(Context,Id,Kind,<<"unavailable">>),S;
incoming(_,_,_,_) -> error(unexpected_time_message).

apply_sample(P,T4,Until,#{scope := {Swarm,_},clock := D0}=S0) ->
    T1 = number(maps:get(<<"t1">>,P)),T2 = number(maps:get(<<"t2">>,P)),T3 = number(maps:get(<<"t3">>,P)),
    Instance = maps:get(<<"instance">>,P),Timeline = ba_swarm_time_protocol:timeline(Swarm,Instance),
    Timeline = maps:get(<<"timeline">>,P),Revision = maps:get(<<"reference_revision">>,P),
    case maps:get(master_instance,D0)=:=Instance of
        true -> true = Revision>=maps:get(reference_revision,D0);
        false -> ok
    end,
    {ok,Sample} = ba_swarm_clock_sync:measure(T1,T2,T3,T4),true = maps:get(round_trip_ns,Sample)=<4000000000,
    Key = {Timeline,Instance,Revision},Stale = age(maps:get(last_sync,D0),T4),
    Reset = maps:get(filter_reference,S0)=/=Key orelse (is_integer(Stale) andalso Stale>freshness(S0)*1000000),
    S = case Reset of true -> reset_filter(S0);false -> S0 end,D = maps:get(clock,S),
    Slot = (mono_ms(T4)-maps:get(born,S)) div maps:get(sample_interval_ms,D),
    Filter = case Slot=:=maps:get(filter_last_slot,S) of
        true -> maps:get(filter,S);false -> ba_swarm_clock_filter:add(Sample,maps:get(filter,S)) end,
    Estimate = ba_swarm_clock_filter:estimate(Filter),
    Full = element(1,Estimate)=:=ok,
    Old = case maps:get(timeline,D)=:=Timeline of true -> maps:get(mapping,D);false -> undefined end,
    Mapping = case {Full,Old,Estimate} of {true,undefined,{ok,Offset}} -> ba_swarm_clock_mapping:new(T4,Offset);_ -> Old end,
    U = case maps:get(<<"uncertainty_ns">>,P) of null -> unknown;B -> number(B)+maps:get(round_trip_ns,Sample) div 2 end,
    NextD = D#{mapping := Mapping,timeline := Timeline,master_instance := Instance,reference_revision := Revision,
        last_sync := T4,confirmed := true,filter_ready := Full,filter_sample_count := ba_swarm_clock_filter:count(Filter),
        measurement_uncertainty_ns := U,round_trip_ns => maps:get(round_trip_ns,Sample),
        sample_authorization_until => Until,last_error := null},
    S#{filter := Filter,filter_reference := Key,filter_last_slot := Slot,clock := NextD}.
correct(#{role := member,clock := D}=S) ->
    case now_ms()>=maps:get(phase_due,S) of
        false -> S;
        true ->
            Next = S#{phase_due := now_ms()+maps:get(interval_ms,D)},
            case {ready(D),ba_swarm_clock_filter:estimate(maps:get(filter,S))} of
                {true,{ok,Target}} ->
                    {M,_,Changed} = ba_swarm_clock_sync:correct(maps:get(mapping,D),mono(),Target,2000000,maps:get(slew_ppm,D)),
                    Next#{clock := D#{mapping := M,revision := maps:get(revision,D)+case Changed of true -> 1;false -> 0 end}};
                _ -> Next
            end
    end;
correct(S) -> S.

upstream(#{blocked := true}=S) -> S;
upstream(#{upstream := undefined}=S) ->
    D = maps:get(clock,S),Due = maps:get(next_external,S),
    case now_ms()>=Due of
        false -> S;
        true ->
            Owner = self(),R = maps:get(reference,S),
            {Pid,Ref} = spawn_monitor(fun() -> Result = try measure(R) catch _:_ -> {error,upstream_failed} end,
                Owner ! {upstream_result,self(),Result} end),
            S#{upstream := #{pid => Pid,monitor => Ref,deadline => now_ms()+4000},last_external_start := now_ms(),next_external := infinity,
                clock := D#{last_error := null}}
    end;
upstream(S) -> S.
apply_upstream({ok,#{offset_ns := Offset,sampled_at := T,uncertainty_ns := U}},#{scope := {Swarm,_},clock := D}=S) ->
    {M,_,_} = ba_swarm_clock_sync:correct(maps:get(mapping,D),T,Offset,2000000,maps:get(slew_ppm,D)),
    Timeline = ba_swarm_time_protocol:timeline(Swarm,maps:get(instance,D)),
    S#{backoff_ms := 30000,next_external := infinity,clock := D#{mapping := M,timeline := Timeline,
        master_instance := maps:get(instance,D),reference_revision := maps:get(reference_revision,D)+1,
        revision := maps:get(revision,D)+1,last_sync := T,confirmed := true,filter_ready := true,
        filter_sample_count := 1,last_error := null,measurement_uncertainty_ns := U,
        upstream_acquisitions := maps:get(upstream_acquisitions,D)+1}};
apply_upstream({error,{kiss_of_death,_}},S) -> fail(kiss_of_death,S#{blocked := true,next_external := infinity});
apply_upstream(_,S) -> upstream_failed(S).
upstream_failed(S) -> Backoff = min(600000,maps:get(backoff_ms,S)*2),
    fail(upstream_unavailable,S#{next_external := now_ms()+Backoff,backoff_ms := Backoff}).
measure(system) -> A = mono(),UTC = erlang:system_time(nanosecond),B = mono(),
    {ok,#{offset_ns => UTC-(A+B) div 2,sampled_at => B,uncertainty_ns => unknown}};
measure({ntp,Host}) -> ba_sntp:query(Host,123,2000);
measure({ntp,Host,Port}) -> ba_sntp:query(Host,Port,2000).

commit(Value,Revision,#{clock := #{offset := P}=D,scope := Scope}=S) ->
    case maps:get(<<"revision">>,P)=:=Revision of
        false -> {{error,conflict},S};
        true ->
            NextP = case maps:get(<<"offset_ms">>,P)=:=Value of
                true -> P;
                false -> P#{<<"revision">> := Revision+1,<<"offset_ms">> := Value}
            end,
            ba_swarm_time_protocol:state(NextP),checkpoint(swarm_time_policy,Scope,NextP),
            Next = S#{clock := D#{offset := NextP,offset_until := infinity}},broadcast(Next),{ok,Next}
    end.
adopt(P,Until,#{clock := #{offset := Old}=D,scope := Scope}=S) ->
    New = ba_swarm_time_protocol:accept(maps:with([<<"revision">>,<<"offset_ms">>],P),Old),
    checkpoint(swarm_time_cache,Scope,New),S#{clock := D#{offset := New,offset_until := Until,offset_error := null}}.
broadcast(#{view := #{policy := #{peers := Peers}}}=S) ->
    P = offset_payload(<<"offset.changed">>,S),
    maps:foreach(fun(Peer,Grants) -> case lists:member(time_read,Grants) of true -> _ = send(Peer,fresh(),P);false -> ok end end,Peers).
offset_payload(Kind,#{clock := #{offset := P}}) -> P#{<<"kind">> => Kind}.
revision(current,#{clock := #{offset := P}=D}) ->
    case offset_ready(D) of true -> maps:get(<<"revision">>,P);false -> {error,offset_unavailable} end;
revision(N,_) when is_integer(N),N>0,N=<9007199254740991 -> N;
revision(_,_) -> {error,invalid_revision}.
checkpoint(Name,{Swarm,Authority},P) ->
    try ok = ba_device_store:save(Name,#{swarm => Swarm,authority => Authority,policy => P})
    catch _:_ -> exit({time_storage_failed,Name}) end.
reply(#{peer := Peer},Id,P) -> send(Peer,Id,P).
reply_error(C,Id,Operation,Reason) -> reply(C,Id,#{<<"kind">> => <<"error">>,<<"operation">> => Operation,<<"reason">> => Reason}).
send(Peer,Id,P) -> ba_swarm_control:time_message(Peer,Id,P).
context(Peer) -> try ba_swarm_control:audio_context(Peer) catch exit:_ -> {error,unavailable} end.
answer(#{caller := From},Result) -> gen_server:reply(From,Result);
answer(_,_) -> ok.
expire(#{pending := Pending}=S) ->
    Rest = maps:filter(fun(_,P) -> case now_ms()<maps:get(deadline,P) of true -> true;false -> answer(P,{error,unconfirmed}),false end end,Pending),
    Next = S#{pending := Rest},
    Current = now_ms(),
    case maps:get(upstream,Next) of
        #{deadline := Due} when Due=<Current -> upstream_failed(cancel_upstream(Next));
        _ -> Next
    end.
invalidate(S) ->
    maps:foreach(fun(_,P) -> answer(P,{error,unconfirmed}) end,maps:get(pending,S)),
    D = maps:get(clock,S),S#{pending := #{},clock := D#{confirmed := false,offset_until := undefined}}.
reset_filter(#{clock := D}=S) ->
    S#{filter := ba_swarm_clock_filter:new(maps:get(filter_required_samples,D)),filter_reference := undefined,filter_last_slot := undefined,
       clock := D#{filter_ready := false,filter_sample_count := 0}}.
fail(Reason,#{clock := D}=S) -> S#{clock := D#{confirmed := false,last_error := Reason}}.
cancel_upstream(#{upstream := undefined}=S) -> S;
cancel_upstream(#{upstream := #{pid := Pid,monitor := Ref}}=S) -> demonitor(Ref,[flush]),exit(Pid,kill),S#{upstream := undefined}.
freshness(#{clock := D}) -> 2*maps:get(sample_interval_ms,D).
save(#{clock := D}=S) -> ets:insert(?MODULE,{clock,D}),S.
valid_reference(system) -> true;
valid_reference({ntp,H}) -> valid_host(H);
valid_reference({ntp,H,P}) -> valid_host(H) andalso is_integer(P) andalso P>0 andalso P<65536;
valid_reference(_) -> false.
valid_host(H) -> is_list(H) andalso H=/=[] andalso length(H)=<253 andalso lists:all(fun(C) -> is_integer(C) andalso C>0 andalso C<128 end,H).
ns(N) -> ba_swarm_time_protocol:encode(N).
number(B) -> ba_swarm_time_protocol:integer(B).
mono() -> erlang:monotonic_time(nanosecond).
now_ms() -> erlang:monotonic_time(millisecond).
mono_ms(N) -> erlang:convert_time_unit(N,nanosecond,millisecond).
fresh() -> binary:encode_hex(crypto:strong_rand_bytes(16)).
age(undefined,_) -> undefined;
age(T,N) -> max(0,N-T).
terminate(_,S) -> cancel_upstream(S),maps:foreach(fun(_,P) -> answer(P,{error,unconfirmed}) end,maps:get(pending,S)),ok.
format_status(Status) -> maps:map(fun(state,S) -> maps:with([scope,role],S);(log,_) -> [];(_,_) -> redacted end,Status).

live(infinity) -> true;
live(Deadline) when is_integer(Deadline) -> now_ms()<Deadline;
live(_) -> false.
