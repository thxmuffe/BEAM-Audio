%% Dynamic local attempts; child specifications are constructed by the Handler.
-module(ba_device_worker_sup).
-behaviour(supervisor).
-export([start_link/0,init/1]).
start_link() -> supervisor:start_link(ba_session_scope:registration(?MODULE),?MODULE,[]).
init([]) -> {ok,{#{strategy => one_for_one,intensity => 5,period => 10},[]}}.
