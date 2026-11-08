%% Installed, non-audio task: wait a bounded duration and report completion.
-module(parvi_device_test_worker).
-behaviour(gen_server).
-export([start_link/1,init/1,handle_call/3,handle_cast/2,handle_info/2]).
start_link(Spec) -> gen_server:start_link(?MODULE,Spec,[]).
init(#{owner := Owner,duration_ms := Duration} = Spec) ->
    Ref = monitor(process,Owner), self() ! ready,
    erlang:send_after(Duration,self(),complete),
    {ok,Spec#{owner_monitor => Ref}}.
handle_call(_,_,S) -> {reply,{error,unsupported},S}.
handle_cast(_,S) -> {noreply,S}.
handle_info(ready,S) -> report(ready,S), {noreply,S};
handle_info(complete,S) -> report(completed,S), {stop,normal,S};
handle_info({'DOWN',Ref,process,_,_},#{owner_monitor := Ref} = S) -> {stop,normal,S};
handle_info(_,S) -> {noreply,S}.
report(Event,#{owner := Owner,id := Id,attempt := Attempt}) ->
    Owner ! {worker_event,self(),Id,Attempt,Event}.
