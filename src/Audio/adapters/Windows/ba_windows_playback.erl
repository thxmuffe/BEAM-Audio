%% Process/device binding only. The shared Erlang receiver owns subscriptions.
-module(ba_windows_playback).
-behaviour(gen_server).
-export([start/0, start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).
start() ->
    case supervisor:start_child(ba_session_scope:ref(ba_sup), #{id => windows_playback,
            start => {?MODULE,start_link,[]}}) of
        {ok,_} -> ok;
        {error,{already_started,_}} -> ok;
        Error -> Error
    end.
start_link() -> gen_server:start_link(ba_session_scope:registration(?MODULE),?MODULE,[],[]).
init([]) ->
    Root = filename:dirname(filename:dirname(code:which(?MODULE))),
    Port = open_port({spawn_executable,filename:join([Root,"audio-runtime","python.exe"])},
        [binary,exit_status,use_stdio,hide,{env,ba_native_env:without_secrets()},{line,4096},
         {args,[filename:join(Root,"webrtc_output.py")]}]),
    receive
        {Port,{data,{eol,Line}}} ->
            #{<<"port">> := Number} = json:decode(Line),
            os:putenv("BA_WEBRTC_AUDIO_PORT",integer_to_list(Number)),
            os:putenv("BA_AUDIO_ENGINE","gstreamer"),
            {ok,#{port => Port}};
        {Port,{exit_status,Code}} -> {stop,{audio_helper_failed,Code}}
    after 30000 -> port_close(Port), {stop,audio_helper_start_timeout}
    end.
handle_call(_,_,S) -> {reply,ok,S}.
handle_cast(_,S) -> {noreply,S}.
handle_info({Port,{exit_status,Code}},#{port := Port} = S) -> {stop,{audio_helper_exit,Code},S};
handle_info(_,S) -> {noreply,S}.
terminate(_,#{port := Port}) ->
    os:unsetenv("BA_WEBRTC_AUDIO_PORT"),
    os:unsetenv("BA_AUDIO_ENGINE"),
    try port_close(Port) catch error:badarg -> ok end, ok.
