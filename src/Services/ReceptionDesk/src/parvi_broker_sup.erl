-module(parvi_broker_sup).
-behaviour(supervisor).
-export([start_link/0, init/1]).
start_link() -> supervisor:start_link({local, ?MODULE}, ?MODULE, []).
init([]) ->
    {ok, {#{strategy => one_for_all, intensity => 5, period => 10}, [
        #{id => parvi_directory, start => {parvi_directory, start_link, []}},
        #{id => parvi_broker_http, start => {parvi_broker_http, start_link, []}}
    ]}}.
