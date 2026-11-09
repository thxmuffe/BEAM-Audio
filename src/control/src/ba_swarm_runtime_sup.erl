%% Dependency ordering inside the runtime, separate from Desk connection failures.
-module(ba_swarm_runtime_sup).
-behaviour(supervisor).
-export([start_link/0,init/1]).
start_link() -> supervisor:start_link({local,?MODULE},?MODULE,[]).
init([]) ->
    {ok,{#{strategy => rest_for_one,intensity => 5,period => 10},
         [#{id => ba_swarm_membership,start => {ba_swarm_membership,start_link,[]}},
          #{id => ba_device_sup,start => {ba_device_sup,start_link,[]},type => supervisor,shutdown => infinity},
          #{id => ba_swarm_control,start => {ba_swarm_control,start_link,[]}},
          #{id => ba_swarm_clock_sup,start => {ba_swarm_clock_sup,start_link,[]},type => supervisor,shutdown => infinity}]}}.
