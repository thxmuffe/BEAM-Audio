-module(parvi_broker_app).
-behaviour(application).
-export([start/2, stop/1]).
start(_Type, _Args) -> parvi_broker_sup:start_link().
stop(_State) -> ok.
