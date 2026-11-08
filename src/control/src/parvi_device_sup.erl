%% Ownership failure domain: stop all attempts before replacing their Handler.
-module(parvi_device_sup).
-behaviour(supervisor).
-export([start_link/0,init/1]).
start_link() -> supervisor:start_link({local,?MODULE},?MODULE,[]).
init([]) ->
    {ok,{#{strategy => rest_for_one,intensity => 5,period => 10},[
        #{id => parvi_device_handler,start => {parvi_device_handler,start_link,[]}},
        #{id => parvi_device_worker_sup,start => {parvi_device_worker_sup,start_link,[]},
          type => supervisor,shutdown => infinity}]}}.
