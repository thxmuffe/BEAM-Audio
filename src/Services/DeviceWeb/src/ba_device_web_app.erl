-module(ba_device_web_app).
-behaviour(application).
-export([start/2,stop/1]).

start(_,_) ->
    ba_device_web_sup:start_link(application:get_env(ba_device_web,options,#{})).
stop(_) -> ok.
