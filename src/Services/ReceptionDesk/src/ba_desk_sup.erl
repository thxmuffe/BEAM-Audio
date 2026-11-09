-module(ba_desk_sup).
-behaviour(supervisor).
-export([start_link/0, init/1]).
start_link() -> supervisor:start_link({local, ?MODULE}, ?MODULE, []).
init([]) ->
    {ok, {#{strategy => one_for_all, intensity => 5, period => 10}, [
        #{id => ba_desk_directory, start => {ba_desk_directory, start_link, []}},
        #{id => ba_desk_http, start => {ba_desk_http, start_link, []}}
    ]}}.
