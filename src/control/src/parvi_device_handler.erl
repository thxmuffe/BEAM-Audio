%% Local resource authority. No network ingress, arbitrary modules or hardware.
-module(parvi_device_handler).
-behaviour(gen_server).
-export([start_link/0,capabilities/0,status/0,enable_test/1,start/2,cancel/1]).
-export([init/1,handle_call/3,handle_cast/2,handle_info/2]).
-define(CAPACITY,2).
-define(HISTORY,16).

start_link() -> gen_server:start_link({local,?MODULE},?MODULE,[],[]).
capabilities() -> gen_server:call(?MODULE,capabilities,100).
status() -> gen_server:call(?MODULE,status).
enable_test(Enabled) -> gen_server:call(?MODULE,{enable_test,Enabled}).
start(Capability,Args) -> gen_server:call(?MODULE,{start,Capability,Args}).
cancel(Id) -> gen_server:call(?MODULE,{cancel,Id}).
init([]) ->
    {ok,#{instance => fresh(),revision => 0,enabled => false,active => #{},history => []}}.

handle_call(capabilities,_,S) -> {reply,capability_snapshot(S),S};
handle_call(status,_,S) ->
    {reply,#{capabilities => capability_snapshot(S),active =>
        maps:map(fun(_,W) -> public(W) end,maps:get(active,S)),history => maps:get(history,S)},S};
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
    Result = try supervisor:start_child(parvi_device_worker_sup,
        #{id => Id,start => {parvi_device_test_worker,start_link,[Spec]},
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
            case supervisor:terminate_child(parvi_device_worker_sup,Id) of
                ok -> ok;
                {error,not_found} -> ok
            end,
            demonitor(Ref,[flush]), finish(Id,Outcome,S)
    end.
finish(Id,Outcome,#{active := Active,history := History} = S) ->
    {W,Rest} = maps:take(Id,Active),
    changed(S#{active := Rest,history := lists:sublist([(public(W))#{state := Outcome}|History],?HISTORY)}).
public(W) -> maps:with([id,attempt,state],W).
changed(S) -> S#{revision := maps:get(revision,S)+1}.
capability_snapshot(#{active := Active,enabled := Enabled,instance := Instance,revision := Revision}) ->
    Count = map_size(Active),
    #{<<"instance">> => Instance,<<"revision">> => Revision,<<"test">> => #{
        <<"supported">> => true,<<"available">> => Enabled andalso Count < ?CAPACITY andalso
            is_pid(whereis(parvi_device_worker_sup)),
        <<"requires_consent">> => true,<<"consent">> => Enabled,
        <<"capacity">> => ?CAPACITY,<<"active">> => Count,<<"max_duration_ms">> => 10000}}.
fresh() -> binary:encode_hex(crypto:strong_rand_bytes(16)).
