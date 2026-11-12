%% Isolate clock-worker restarts from the root's rest_for_one audio lifecycle.
-module(ba_buffee_clock_sup).
-behaviour(supervisor).
-export([start_link/0, init/1]).

start_link() -> supervisor:start_link(ba_session_scope:registration(?MODULE), ?MODULE, []).
init([]) ->
    {ok, {#{strategy => one_for_one, intensity => 5, period => 10},
        [#{id => ba_buffee_clock, start => {ba_buffee_clock, start_link, []}}]}}.
