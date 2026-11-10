-module(ba_device_web_app).
-behaviour(application).
-export([start/2,stop/1]).

start(_,_) ->
    case ba_device_web_sup:start_link(application:get_env(ba_device_web,options,#{})) of
        {ok,_}=Started ->
            application:set_env(ba_device_web,origin,ba_device_web_sup:origin()),Started;
        Error -> Error
    end.
stop(_) -> application:unset_env(ba_device_web,origin).
