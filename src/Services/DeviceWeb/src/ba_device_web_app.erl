-module(ba_device_web_app).
-behaviour(application).
-export([start/2,stop/1]).

start(_,_) ->
    case ba_device_web_sup:start_link(application:get_env(ba_device_web,options,#{})) of
        {ok,_}=Started ->
            persistent_term:put({ba_device_web,origin},ba_device_web_sup:origin()),Started;
        Error -> Error
    end.
%% The application controller waits for stop/1, so this callback must not call it.
stop(_) -> persistent_term:erase({ba_device_web,origin}),ok.
