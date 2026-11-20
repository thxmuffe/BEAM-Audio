-module(ba_app).
-behaviour(application).
-export([start/2, stop/1]).

start(_Type, _Args) ->
    %% Configure the platform before starting any restore/audio owners.
    ba_app_session:configure(),
    ba_sup:start_link().
stop(_State) -> ok.
