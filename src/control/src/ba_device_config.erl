%% Durable desired Device settings. Runtime observations and Buffee state are not
%% configuration. One serialized owner records changes from every supported client.
-module(ba_device_config).
-behaviour(gen_server).
-export([start_link/0,consent/0,snapshot/0,change/2,undo/1,redo/1,allowed/1,token/1]).
-export([init/1,handle_call/3,handle_cast/2,handle_info/2,format_status/1]).
-define(LIMIT,100).
start_link() -> gen_server:start_link(ba_session_scope:registration(?MODULE),?MODULE,[],[]).
consent() -> gen_server:call(ba_session_scope:ref(?MODULE),consent).
snapshot() -> gen_server:call(ba_session_scope:ref(?MODULE),snapshot).
change(Patch,Options) -> gen_server:call(ba_session_scope:ref(?MODULE),{edit,Patch,Options}).
undo(Options) -> gen_server:call(ba_session_scope:ref(?MODULE),{undo,Options}).
redo(Options) -> gen_server:call(ba_session_scope:ref(?MODULE),{redo,Options}).
%% Read-only, fail-closed view for hot execution paths. Only this owner writes it.
allowed(Key) ->
    case application:get_env(ba_core,runtime_profile,legacy_apps) of
        buffee_control ->
            try ets:lookup(?MODULE,permissions) of
                [{permissions,C,_,Registry}] -> Registry=/=undefined andalso Registry=:=whereis(ba_permission_pg) andalso maps:get(Key,C,false)=:=true;
                _ -> false
            catch error:badarg -> false end;
        _ -> true % Explicit legacy compatibility profile; not the secure path.
    end.
init([]) ->
    ets:new(?MODULE,[named_table,protected,set,{read_concurrency,true}]),
    Secure=application:get_env(ba_core,runtime_profile,legacy_apps)=:=buffee_control,
    Default=case Secure of
        true -> #{speaker => false,microphone => false,broadcast => false,calibrate => false,dsp => false};
        false -> application:get_env(ba_core,audio_consent,#{speaker => true,microphone => false,broadcast => false})
    end,
    Initial=#{format => 1,revision => 0,cursor => 0,seen => [],
        states => [#{label => <<"Initial audio settings">>,config => Default,time_ms => erlang:system_time(millisecond)}]},
    ok=validate(Initial),
    Saved=case Secure of true -> undefined;false -> ba_device_store:load(device_configuration,undefined) end,
    S=case Saved of undefined -> ok=ba_device_store:save(device_configuration,Initial),Initial;_ -> validate(Saved),Saved end,
    publish(S),changed(),{ok,S#{permission_registry => whereis(ba_permission_pg)}}.
validate(#{format := 1,revision := R,cursor := C,seen := Seen,states := States}) ->
    true=is_integer(R) andalso R>=0,true=is_list(States) andalso length(States)>0 andalso length(States)=< ?LIMIT+1,
    true=is_integer(C) andalso C>=0 andalso C<length(States),true=is_list(Seen) andalso length(Seen)=< ?LIMIT,
    true=lists:all(fun(Id) -> is_binary(Id) andalso byte_size(Id)>0 andalso byte_size(Id)=<128 end,Seen),
    [begin true=valid_config(Config),true=is_binary(Label),true=is_integer(T) end || #{config := Config,label := Label,time_ms := T} <- States],
    true=lists:all(fun(E) -> is_map(E) andalso maps:is_key(config,E) andalso maps:is_key(label,E) andalso maps:is_key(time_ms,E) end,States),ok.
valid_config(C) when is_map(C) ->
    lists:all(fun(K) -> maps:is_key(K,C) end,[broadcast,microphone,speaker]) andalso
    lists:all(fun(K) -> lists:member(K,[broadcast,microphone,speaker,calibrate,dsp]) end,maps:keys(C)) andalso lists:all(fun is_boolean/1,maps:values(C));
valid_config(_) -> false.
current(#{states := States,cursor := C}) -> maps:get(config,lists:nth(C+1,States)).
public(#{states := States,cursor := C,revision := R}=S) ->
    #{revision => R,consent => current(S),revocation_pending => maps:get(revocation_pending,S,[]),can_undo => C>0 andalso history_allowed(current(S),maps:get(config,lists:nth(max(1,C),States))),can_redo => C+1<length(States) andalso history_allowed(current(S),maps:get(config,lists:nth(min(length(States),C+2),States))),
      undo_label => case C of 0 -> null;_ -> maps:get(label,lists:nth(C+1,States)) end,
      redo_label => case C+1<length(States) of true -> maps:get(label,lists:nth(C+2,States));false -> null end,
      cursor => C,entries => [E#{selected => I=:=C} || {I,E} <- lists:zip(lists:seq(0,length(States)-1),States)]}.
handle_call(consent,_,S) -> {reply,current(S),S};
handle_call(snapshot,_,S) -> {reply,public(S),S};
handle_call(Command,_,S) ->
    try operation(Command,S) of
        unchanged -> case maps:get(revocation_pending,S,[]) of [] -> {reply,ok,S};_ -> commit(S,S) end;
        {error,R} -> {reply,{error,R},S};
        Next -> commit(S,Next)
    catch error:badarg -> {reply,{error,invalid_configuration},S};
          error:{badmatch,false} -> {reply,{error,invalid_configuration},S};
          error:function_clause -> {reply,{error,invalid_configuration},S}
    end.
commit(Old,Next) ->
    case application:get_env(ba_core,runtime_profile,legacy_apps)=/=buffee_control orelse maps:get(permission_registry,Old,whereis(ba_permission_pg))=:=whereis(ba_permission_pg) of
        true -> commit_registered(Old,Next);false -> {reply,{error,permission_registry_lost},Old}
    end.
commit_registered(Old,Next) ->
    Removed=[K || K <- [speaker,microphone,calibrate,dsp],maps:get(K,current(Old),false),not maps:get(K,current(Next),false)],
    Added=[K || K <- [speaker,microphone,calibrate,dsp],not maps:get(K,current(Old),false),maps:get(K,current(Next),false)],
    Pending=maps:get(revocation_pending,Old,[]),
    case {Removed,Added,Pending} of
        {[_|_],[_|_],_} -> {reply,{error,separate_permission_changes_required},Old};
        {_,[_|_],[_|_]} -> {reply,{error,revocation_incomplete},Old};
        {[],_,[]} ->
            case persist(Next) of
                ok -> publish(Next),changed(),{reply,ok,Next};
                {error,R} -> {reply,{error,R},Old}
            end;
        _ ->
            %% Deny BEFORE stopping or disk I/O. A failure never restores a grant.
            publish(Next),Keys=lists:usort(Removed++Pending),
            Stop=ba_device_permission:revoke(Keys,maps:get(revocation_executors,Old,[])),Saved=persist(Next),changed(),
            case {Stop,Saved} of
                {ok,ok} -> {reply,ok,Next#{revocation_pending => [],revocation_executors => []}};
                {ok,{error,R}} -> {reply,{error,R},Next#{revocation_pending => [],revocation_executors => []}};
                {{error,Failed},_} -> {reply,{error,revocation_incomplete},Next#{revocation_pending => Keys,revocation_executors => Failed}}
            end
    end.
operation(Command,S) ->
    Options=element(tuple_size(Command),Command),true=is_map(Options),
    Id=maps:get(request_id,Options,undefined),Expected=maps:get(expected_revision,Options,maps:get(revision,S)),
    case Id=/=undefined andalso lists:member(Id,maps:get(seen,S)) of
        true -> unchanged;
        false ->
            case Expected=:=maps:get(revision,S) of
                false -> {error,configuration_changed};
                true ->
                    true=Id=:=undefined orelse (is_binary(Id) andalso byte_size(Id)>0 andalso byte_size(Id)=<128),
                    case apply_command(Command,S) of
                        unchanged when Id=:=undefined -> unchanged;
                        unchanged -> S#{seen := lists:sublist([Id|maps:get(seen,S)],?LIMIT)};
                        {error,_}=E -> E;
                        Next -> Next#{revision := maps:get(revision,S)+1,
                            seen := case Id of undefined -> maps:get(seen,S);_ -> lists:sublist([Id|maps:get(seen,S)],?LIMIT) end}
                    end
            end
    end.
apply_command({edit,Patch,_},S) when is_map(Patch) ->
    Old=current(S),New=maps:merge(Old,Patch),true=valid_config(New),
    case New=:=Old of
        true -> unchanged;
        false ->
            Changed=[K || K <- [speaker,microphone,broadcast,calibrate,dsp],maps:get(K,Old,false)=/=maps:get(K,New,false)],
            Label=case Changed of
                [K] -> <<(case maps:get(K,New) of true -> <<"Enable ">>;false -> <<"Disable ">> end)/binary,(atom_to_binary(K))/binary>>;
                _ -> <<"Change audio capabilities">>
            end,
            Entry=#{label => Label,config => New,time_ms => erlang:system_time(millisecond)},
            States=lists:sublist(maps:get(states,S),maps:get(cursor,S)+1)++[Entry],
            Kept=lists:nthtail(max(0,length(States)-?LIMIT-1),States),S#{states := Kept,cursor := length(Kept)-1}
    end;
apply_command({undo,_},#{cursor := 0}) -> {error,nothing_to_undo};
apply_command({undo,_},#{cursor := C}=S) -> history_edit(S,S#{cursor := C-1});
apply_command({redo,_},#{cursor := C,states := States}) when C+1>=length(States) -> {error,nothing_to_redo};
apply_command({redo,_},#{cursor := C}=S) -> history_edit(S,S#{cursor := C+1}).
history_edit(Old,New) -> case history_allowed(current(Old),current(New)) of true -> New;false -> {error,local_approval_required} end.
persist(S) -> try ba_device_store:save(device_configuration,S) of ok -> ok;_ -> {error,configuration_save_failed}
              catch _:_ -> {error,configuration_save_failed} end.
token(Key) ->
    case application:get_env(ba_core,runtime_profile,legacy_apps) of
        buffee_control -> try ets:lookup(?MODULE,permissions) of
            [{permissions,C,T,Registry}] -> case Registry=/=undefined andalso Registry=:=whereis(ba_permission_pg) andalso maps:get(Key,C,false) of true -> {ok,maps:get(Key,T)};false -> {error,consent_required} end;
            _ -> {error,consent_required}
        catch error:badarg -> {error,consent_required} end;
        _ -> {ok,legacy}
    end.
publish(S) ->
    C=current(S),{Previous,Tokens}=case ets:lookup(?MODULE,permissions) of
        [{permissions,PC,PT,_}] -> {PC,PT};[] -> {#{},#{}} end,
    T=maps:map(fun(K,V) -> case maps:get(K,Previous,undefined)=:=V of
        true -> maps:get(K,Tokens,make_ref());false -> make_ref() end end,C),
    ets:insert(?MODULE,{permissions,C,T,whereis(ba_permission_pg)}),ok.
changed() ->
    Names=[ba_device_handler|[{global,N} || {ba_session,_,ba_device_handler}=N <- global:registered_names()]],
    [gen_server:cast(Name,audio_changed) || Name <- Names],ok.
history_allowed(Old,New) ->
    application:get_env(ba_core,runtime_profile,legacy_apps)=/=buffee_control orelse
    not lists:any(fun(K) -> maps:get(K,New,false) andalso not maps:get(K,Old,false) end,[speaker,microphone,calibrate,dsp]).
handle_cast(_,S) -> {noreply,S}.
handle_info(_,S) -> {noreply,S}.
format_status(Status) -> maps:map(fun(state,S) -> maps:with([revision,cursor],S);(log,_) -> [];(_,_) -> redacted end,Status).
