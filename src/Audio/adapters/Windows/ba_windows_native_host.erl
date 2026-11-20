%% Windows receiving host: keeps one ba_native_stream.exe --host running and
%% names its local control port in BA_NATIVE_STREAM_PORT, as the iPhone app
%% does for its in-process host. ba_native_media_session connects there for
%% every received stream. The helper exits when this owner's heartbeats stop.
-module(ba_windows_native_host).
-behaviour(gen_server).
-export([start/0]).
-export([init/1,handle_call/3,handle_cast/2,handle_info/2,terminate/2]).
%% No helper in this build: the Device runs without playback, as before.
start() ->
    case ba_windows_native_audio:helper() of
        false -> ok;
        _ -> case gen_server:start({local,?MODULE},?MODULE,[],[]) of
            {ok,_} -> ok;{error,{already_started,_}} -> ok;Error -> Error end
    end.
init([]) ->
    process_flag(trap_exit,true),
    erlang:send_after(250,self(),heartbeat),
    {ok,launch(#{failures => 0})}.
launch(S) ->
    Port=open_port({spawn_executable,ba_windows_native_audio:helper()},[binary,{packet,4},exit_status,use_stdio,hide,
        {args,["--host"]},{env,ba_windows_native_audio:child_env()}]),
    S#{port => Port}.
handle_call(_,_,S) -> {reply,{error,unsupported},S}.
handle_cast(_,S) -> {noreply,S}.
handle_info(heartbeat,S) ->
    case maps:find(port,S) of {ok,Port} -> try port_command(Port,<<$h>>) catch error:_ -> ok end;error -> ok end,
    erlang:send_after(250,self(),heartbeat),{noreply,S};
handle_info({Port,{data,<<9,P:16>>}},#{port := Port}=S) ->
    os:putenv("BA_NATIVE_STREAM_PORT",integer_to_list(P)),{noreply,S#{failures := 0}};
handle_info({Port,{data,<<3,_:32/little-signed,Text/binary>>}},#{port := Port}=S) ->
    logger:warning("Windows native stream host: ~ts",[Text]),{noreply,S};
handle_info({Port,{exit_status,Code}},#{port := Port,failures := F}=S) ->
    %% Streams on the old port end with it; new ones wait for the relaunch.
    os:unsetenv("BA_NATIVE_STREAM_PORT"),
    logger:warning("Windows native stream host exited (~B); restarting",[Code]),
    erlang:send_after(min(30000,500 bsl min(F,6)),self(),relaunch),
    {noreply,(maps:remove(port,S))#{failures := F+1}};
handle_info(relaunch,S) -> {noreply,launch(S)};
handle_info(_,S) -> {noreply,S}.
terminate(_,S) ->
    os:unsetenv("BA_NATIVE_STREAM_PORT"),
    case maps:find(port,S) of {ok,Port} -> ba_native_stop:port(Port,<<$s>>,<<6>>);error -> ok end,ok.
