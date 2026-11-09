%% Temporary network workers; the Desk owner reconciles desired connections.
%% A repeatedly crashing worker cannot exhaust a shared restart budget.
-module(ba_desk_connections_sup).
-behaviour(supervisor).
-export([start_link/0,init/1,ensure/2,stop/1,connections/0]).
start_link() -> supervisor:start_link({local,?MODULE},?MODULE,[]).
init([]) -> {ok,{#{strategy => one_for_one,intensity => 8,period => 10},[]}}.
ensure(URL,Options) ->
    case supervisor:start_child(?MODULE,#{id => URL,start => {ba_relay,start_link,[Options]},restart => temporary}) of
        {ok,P} -> P;
        {error,{already_started,P}} -> P;
        {error,already_present} ->
            case supervisor:restart_child(?MODULE,URL) of {ok,P} -> P;_ -> undefined end;
        {error,_} -> undefined
    end.
stop(URL) -> supervisor:terminate_child(?MODULE,URL),supervisor:delete_child(?MODULE,URL).
connections() ->
    try maps:from_list([{URL,P} || {URL,P,_,_} <- supervisor:which_children(?MODULE),is_pid(P)])
    catch exit:_ -> #{} end.
