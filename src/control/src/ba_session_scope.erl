%% Local Session namespaces. Device identity, contacts and Reception sockets stay shared.
-module(ba_session_scope).
-export([init/0,enter/1,current/0,run/2,ref/1,registration/1,whereis/1,
         new_table/2,table/1,state_directory/1,set_env/2,unset_env/1,get_env/1,get_env/2,
         spawn/1,spawn_link/1,spawn_monitor/1,clear/1]).
-define(TABLE,ba_session_registry).
init() -> ets:new(?TABLE,[named_table,public,set,{read_concurrency,true}]),ok.
enter(Scope) -> put(ba_session_scope,Scope),ets:insert(?TABLE,{{process,self()},Scope}),ok.
current() ->
    case get(ba_session_scope) of
        undefined ->
            Ancestors=case get('$ancestors') of L when is_list(L) -> L;_ -> [] end,
            find(Ancestors);
        Scope -> Scope
    end.
find([]) -> undefined;
find([P|Rest]) ->
    try ets:lookup(?TABLE,{process,ancestor(P)}) of
        [{_,Scope}] -> put(ba_session_scope,Scope),Scope;
        _ -> find(Rest)
    catch error:badarg -> find(Rest) end.
ancestor({global,Name}) -> global:whereis_name(Name);
ancestor(Name) when is_atom(Name) -> erlang:whereis(Name);
ancestor(Pid) -> Pid.
run(Scope,F) -> Old=get(ba_session_scope),put(ba_session_scope,Scope),
    try F() after put(ba_session_scope,Old) end.
shared(N) -> lists:member(N,[ba_permission_pg,ba_device_config,ba_contacts,ba_relay,ba_desk_connections_sup,ba_sessions,
                            ba_cli_device,ba_device_web_sup,ba_device_web]).
scoped(N) when is_atom(N) -> lists:prefix("ba_",atom_to_list(N)) andalso not shared(N);
scoped(_) -> false.
ref(N) -> case {current(),scoped(N)} of {undefined,_} -> N;{_,false} -> N;
    {Scope,true} -> {global,{ba_session,Scope,N}} end.
registration(N) -> case ref(N) of N -> {local,N};R -> R end.
whereis(N) -> case ref(N) of {global,Key} -> global:whereis_name(Key);Other -> erlang:whereis(Other) end.
new_table(Name,Options) ->
    case current() of
        undefined -> ets:new(Name,Options);
        Scope -> Tid=ets:new(Name,lists:delete(named_table,Options)),
                 ets:insert(?TABLE,{{table,Scope,Name},Tid}),Tid
    end.
table(Name) -> case current() of undefined -> Name;Scope ->
    case ets:lookup(?TABLE,{table,Scope,Name}) of [{_,Tid}] -> Tid;[] -> undefined end end.
state_directory(Name) ->
    case {os:getenv("BA_STATE_DIR"),current(),Name} of
        {false,_,_} -> false;
        {Root,_,device_configuration} -> Root;
        {Root,_,contacts} -> Root;
        {Root,_,web_sessions} -> Root;
        {Root,undefined,_} -> Root;
        {Root,Scope,_} -> filename:join([Root,"sessions",binary_to_list(Scope)])
    end.
set_env(Key,Value) -> case current() of undefined -> application:set_env(ba_core,Key,Value);
    Scope -> ets:insert(?TABLE,{{env,Scope,Key},Value}),ok end.
unset_env(Key) -> case current() of undefined -> application:unset_env(ba_core,Key);
    Scope -> ets:delete(?TABLE,{env,Scope,Key}),ok end.
get_env(Key) -> case current() of undefined -> application:get_env(ba_core,Key);Scope ->
    case ets:lookup(?TABLE,{env,Scope,Key}) of [{_,V}] -> {ok,V};[] -> application:get_env(ba_core,Key) end end.
get_env(Key,Default) -> case get_env(Key) of {ok,V} -> V;undefined -> Default end.
spawn(F) -> Scope=current(),erlang:spawn(fun() -> run(Scope,F) end).
spawn_link(F) -> Scope=current(),erlang:spawn_link(fun() -> run(Scope,F) end).
spawn_monitor(F) -> Scope=current(),erlang:spawn_monitor(fun() -> run(Scope,F) end).
clear(Scope) -> ets:match_delete(?TABLE,{{table,Scope,'_'},'_'}),
    ets:match_delete(?TABLE,{{env,Scope,'_'},'_'}),ets:match_delete(?TABLE,{{process,'_'},Scope}),ok.
