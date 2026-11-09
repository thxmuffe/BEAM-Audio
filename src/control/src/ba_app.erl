-module(ba_app).
-behaviour(application).
-export([start/2, stop/1]).

start(_Type, _Args) ->
    %% Releases may start the application before the native bridge entry point.
    %% Configure both Apple hosts before starting any restore/audio owners.
    case application:get_env(ba_core,runtime_profile,legacy_apps) of
        swarm_control -> ba_app_session:configure();
        _ -> ok
    end,
    ba_sup:start_link().
stop(_State) -> ok.
