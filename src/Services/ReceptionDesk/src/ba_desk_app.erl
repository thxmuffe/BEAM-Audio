-module(ba_desk_app).
-behaviour(application).
-export([start/2, stop/1]).
start(_Type, _Args) -> ba_desk_sup:start_link().
stop(_State) -> ok.
