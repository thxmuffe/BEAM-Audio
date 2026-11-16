%% The Device's settings: one plain-text file a person can read and edit
%% (`settings.config`, Erlang terms read with file:consult/1). Every change is
%% written soon after it happens: changes within ?DELAY ms share one write, and a
%% write replaces the file atomically, so after a crash the Device starts from
%% the last saved settings.
%%
%% It is also the single read path for launch configuration: environment
%% variables and ba_core application settings are read through env/1 and app/2,
%% and the file may override either ({environment,#{}} and {runtime,#{}}).
%% Secrets never pass through here.
-module(ba_settings).
-behaviour(gen_server).
-export([start_link/0,get/1,get/2,put/2,update/3,flush/0,path/0]).
-export([env/1,env/2,app/1,app/2]).
-export([init/1,handle_call/3,handle_cast/2,handle_info/2,terminate/2]).
-define(TABLE,?MODULE).
-define(DELAY,200).
%% Read from the process environment only; never from or into the file.
-define(SECRETS,["BA_IDENTITY_SEED"]).

start_link() -> gen_server:start_link({local,?MODULE},?MODULE,[],[]).

get(Key) -> get(Key,undefined).
get(Key,Default) ->
    try ets:lookup(?TABLE,Key) of [{_,V}] -> V;[] -> Default
    catch error:badarg -> Default end.
%% Without a running settings owner (unit tests of single processes) a change
%% stays in the caller and is not saved.
put(Key,Value) -> case whereis(?MODULE) of undefined -> ok;_ -> gen_server:call(?MODULE,{put,Key,Value}) end.
%% Atomic read-modify-write for values shared by several writers.
update(Key,Fun,Default) ->
    case whereis(?MODULE) of undefined -> Fun(Default);_ -> gen_server:call(?MODULE,{update,Key,Fun,Default}) end.
%% Write now (for tests and orderly shutdown).
flush() -> gen_server:call(?MODULE,flush).

%% An environment variable, unless the file overrides it. Same return values as os:getenv/1,2.
env(Name) -> env(Name,false).
env(Name,Default) ->
    case lists:member(Name,?SECRETS) of
        true -> os:getenv(Name,Default);
        false ->
            case maps:find(Name,get(environment,#{})) of
                {ok,V} when is_list(V) -> V;
                _ -> os:getenv(Name,Default)
            end
    end.
%% A ba_core application setting, unless the file overrides it.
app(Key) ->
    case maps:find(Key,get(runtime,#{})) of
        {ok,V} -> {ok,V};
        error -> application:get_env(ba_core,Key)
    end.
app(Key,Default) -> case app(Key) of {ok,V} -> V;undefined -> Default end.

%% Device-wide, beside identity and other private state; none when the runtime is ephemeral.
path() ->
    case os:getenv("BA_STATE_DIR") of
        false -> undefined;
        "" -> undefined;
        Dir -> filename:join(Dir,"settings.config")
    end.

init([]) ->
    process_flag(trap_exit,true),
    ets:new(?TABLE,[named_table,protected,set,{read_concurrency,true}]),
    Exists=path()=/=undefined andalso filelib:is_regular(path()),
    ets:insert(?TABLE,read(path())),
    %% One-time import from the binary files used before this file existed.
    Imported=case path()=/=undefined andalso not Exists of true -> import();false -> [] end,
    ets:insert(?TABLE,Imported),
    S=#{timer => undefined,dirty => false},
    {ok,case Imported of [] -> S;_ -> later(S) end}.

import() ->
    %% The old binary files are read in safe mode: their atoms must already exist.
    [code:ensure_loaded(M) || M <- [ba_contacts,ba_device_config,ba_buffee,ba_sessions]],
    Old=fun(Name) -> try ba_device_store:load(Name,undefined) catch _:_ -> undefined end end,
    Consent=case Old(device_configuration) of
        #{states := States,cursor := C} when is_list(States),length(States)>C -> maps:get(config,lists:nth(C+1,States),undefined);
        _ -> undefined
    end,
    [{K,V} || {K,V} <- [{consent,Consent},{automation,Old(device_gates)},{contacts,Old(contacts)}],is_map(V)]++
    [{open_sessions,T} || T <- [Old(web_sessions)],is_list(T)].

handle_call({put,Key,Value},_,S) -> ets:insert(?TABLE,{Key,Value}),{reply,ok,later(S)};
handle_call({update,Key,Fun,Default},_,S) ->
    Value=Fun(get(Key,Default)),ets:insert(?TABLE,{Key,Value}),{reply,Value,later(S)};
handle_call(flush,_,S) -> {reply,write(path()),S#{dirty := false}};
handle_call(_,_,S) -> {reply,{error,unsupported},S}.
handle_cast(_,S) -> {noreply,S}.
handle_info(write,S) -> _=write(path()),{noreply,S#{timer := undefined,dirty := false}};
handle_info(_,S) -> {noreply,S}.
terminate(_,#{dirty := true}) -> _=write(path()),ok;
terminate(_,_) -> ok.

later(#{timer := undefined}=S) -> S#{timer := erlang:send_after(?DELAY,self(),write),dirty := true};
later(S) -> S#{dirty := true}.

read(undefined) -> [];
read(Path) ->
    case file:consult(Path) of
        {ok,Terms} -> [T || {K,_}=T <- Terms,is_atom(K)];
        {error,enoent} -> [];
        {error,Reason} ->
            %% Keep the unreadable file for the person to fix; start from defaults.
            logger:error("Settings file ~ts is unreadable (~p); kept as .broken",[Path,Reason]),
            _=file:rename(Path,Path++".broken"),[]
    end.

write(undefined) -> ok;
write(Path) ->
    Terms=lists:sort(ets:tab2list(?TABLE)),
    Text=[<<"%% BEAM Audio Device settings. Plain Erlang terms; edit with care while the app is closed.\n">>,
          [io_lib:format("~tp.~n",[T]) || T <- Terms]],
    Temp=Path++".tmp",
    try
        ok=filelib:ensure_dir(Path),
        {ok,F}=file:open(Temp,[write,binary,raw]),
        try ok=file:change_mode(Temp,8#600),ok=file:write(F,unicode:characters_to_binary(Text)),ok=file:sync(F)
        after ok=file:close(F) end,
        ok=file:rename(Temp,Path)
    catch Class:Reason ->
        logger:error("Settings not saved to ~ts: ~p:~p",[Path,Class,Reason]),{error,settings_not_saved}
    end.
