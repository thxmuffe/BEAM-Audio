%% Durable desired Device settings. Runtime observations and Swarm state are not
%% configuration. One serialized owner records changes from every supported client.
-module(ba_device_config).
-behaviour(gen_server).
-export([start_link/0,consent/0,snapshot/0,change/2,undo/1,redo/1]).
-export([init/1,handle_call/3,handle_cast/2,handle_info/2,format_status/1]).
-define(LIMIT,100).
start_link() -> gen_server:start_link({local,?MODULE},?MODULE,[],[]).
consent() -> gen_server:call(?MODULE,consent).
snapshot() -> gen_server:call(?MODULE,snapshot).
change(Patch,Options) -> gen_server:call(?MODULE,{edit,Patch,Options}).
undo(Options) -> gen_server:call(?MODULE,{undo,Options}).
redo(Options) -> gen_server:call(?MODULE,{redo,Options}).
init([]) ->
    Default=application:get_env(ba_core,audio_consent,#{speaker => true,microphone => false,broadcast => false}),
    Initial=#{format => 1,revision => 0,cursor => 0,seen => [],
        states => [#{label => <<"Initial audio settings">>,config => Default,time_ms => erlang:system_time(millisecond)}]},
    ok=validate(Initial),
    Saved=ba_device_store:load(device_configuration,undefined),
    S=case Saved of undefined -> ok=ba_device_store:save(device_configuration,Initial),Initial;_ -> validate(Saved),Saved end,
    changed(),{ok,S}.
validate(#{format := 1,revision := R,cursor := C,seen := Seen,states := States}) ->
    true=is_integer(R) andalso R>=0,true=is_list(States) andalso length(States)>0 andalso length(States)=< ?LIMIT+1,
    true=is_integer(C) andalso C>=0 andalso C<length(States),true=is_list(Seen) andalso length(Seen)=< ?LIMIT,
    true=lists:all(fun(Id) -> is_binary(Id) andalso byte_size(Id)>0 andalso byte_size(Id)=<128 end,Seen),
    [begin true=valid_config(Config),true=is_binary(Label),true=is_integer(T) end || #{config := Config,label := Label,time_ms := T} <- States],
    true=lists:all(fun(E) -> is_map(E) andalso maps:is_key(config,E) andalso maps:is_key(label,E) andalso maps:is_key(time_ms,E) end,States),ok.
valid_config(C) when is_map(C),map_size(C)=:=3 ->
    lists:sort(maps:keys(C))=:=[broadcast,microphone,speaker] andalso lists:all(fun is_boolean/1,maps:values(C));
valid_config(_) -> false.
current(#{states := States,cursor := C}) -> maps:get(config,lists:nth(C+1,States)).
public(#{states := States,cursor := C,revision := R}=S) ->
    #{revision => R,consent => current(S),can_undo => C>0,can_redo => C+1<length(States),
      undo_label => case C of 0 -> null;_ -> maps:get(label,lists:nth(C+1,States)) end,
      redo_label => case C+1<length(States) of true -> maps:get(label,lists:nth(C+2,States));false -> null end,
      cursor => C,entries => [E#{selected => I=:=C} || {I,E} <- lists:zip(lists:seq(0,length(States)-1),States)]}.
handle_call(consent,_,S) -> {reply,current(S),S};
handle_call(snapshot,_,S) -> {reply,public(S),S};
handle_call(Command,_,S) ->
    try operation(Command,S) of
        unchanged -> {reply,ok,S};
        {error,R} -> {reply,{error,R},S};
        Next ->
            case persist(Next) of
                ok -> case current(Next)=:=current(S) of true -> ok;false -> changed() end,{reply,ok,Next};
                {error,R} -> {reply,{error,R},S}
            end
    catch error:badarg -> {reply,{error,invalid_configuration},S};
          error:{badmatch,false} -> {reply,{error,invalid_configuration},S};
          error:function_clause -> {reply,{error,invalid_configuration},S}
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
            Changed=[K || K <- [speaker,microphone,broadcast],maps:get(K,Old)=/=maps:get(K,New)],
            Label=case Changed of
                [K] -> <<(case maps:get(K,New) of true -> <<"Enable ">>;false -> <<"Disable ">> end)/binary,(atom_to_binary(K))/binary>>;
                _ -> <<"Change audio capabilities">>
            end,
            Entry=#{label => Label,config => New,time_ms => erlang:system_time(millisecond)},
            States=lists:sublist(maps:get(states,S),maps:get(cursor,S)+1)++[Entry],
            Kept=lists:nthtail(max(0,length(States)-?LIMIT-1),States),S#{states := Kept,cursor := length(Kept)-1}
    end;
apply_command({undo,_},#{cursor := 0}) -> {error,nothing_to_undo};
apply_command({undo,_},#{cursor := C}=S) -> S#{cursor := C-1};
apply_command({redo,_},#{cursor := C,states := States}) when C+1>=length(States) -> {error,nothing_to_redo};
apply_command({redo,_},#{cursor := C}=S) -> S#{cursor := C+1}.
persist(S) -> try ba_device_store:save(device_configuration,S) of ok -> ok;_ -> {error,configuration_save_failed}
              catch _:_ -> {error,configuration_save_failed} end.
changed() -> case whereis(ba_device_handler) of undefined -> ok;_ -> ba_device_handler:audio_changed() end.
handle_cast(_,S) -> {noreply,S}.
handle_info(_,S) -> {noreply,S}.
format_status(Status) -> maps:map(fun(state,S) -> maps:with([revision,cursor],S);(log,_) -> [];(_,_) -> redacted end,Status).
