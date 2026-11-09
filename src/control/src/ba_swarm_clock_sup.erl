%% Isolate clock-worker restarts from the root's rest_for_one audio lifecycle.
-module(ba_swarm_clock_sup).
-behaviour(supervisor).
-export([start_link/0, init/1]).

start_link() -> supervisor:start_link({local, ?MODULE}, ?MODULE, []).
init([]) ->
    {ok, {#{strategy => one_for_one, intensity => 5, period => 10},
        [#{id => ba_swarm_clock, start => {ba_swarm_clock, start_link, []}}]}}.
