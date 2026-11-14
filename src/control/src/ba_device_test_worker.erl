%% Installed, non-audio task: wait a bounded duration and report completion.
-module(ba_device_test_worker).
-behaviour(gen_server).
-export([start_link/1,init/1,handle_call/3,handle_cast/2,handle_info/2]).
start_link(Spec) -> gen_server:start_link(?MODULE,Spec,[]).
init(Spec) -> case ba_device_permission:allowed(dsp) of
    true -> case ba_device_permission:enter(dsp) of {ok,T} -> init_permitted(Spec#{permission_token => T});E -> {stop,E} end;false -> {stop,consent_required} end.
init_permitted(#{owner := Owner,duration_ms := Duration} = Spec) ->
    Ref = monitor(process,Owner), self() ! ready,
    erlang:send_after(Duration,self(),complete),
    {ok,Spec#{owner_monitor => Ref}}.
handle_call({revoke_permissions,_},_,S) -> {stop,normal,ok,S};
handle_call(_,_,S) -> {reply,{error,unsupported},S}.
handle_cast(_,S) -> {noreply,S}.
handle_info(ready,S) -> report(ready,S), {noreply,S};
handle_info(complete,S) -> report(completed,S), {stop,normal,S};
handle_info({'DOWN',Ref,process,_,_},#{owner_monitor := Ref} = S) -> {stop,normal,S};
handle_info(_,S) -> {noreply,S}.
report(Event,#{owner := Owner,id := Id,attempt := Attempt}) ->
    Owner ! {worker_event,self(),Id,Attempt,Event}.
