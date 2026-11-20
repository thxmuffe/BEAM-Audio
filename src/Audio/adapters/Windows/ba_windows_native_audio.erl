%% Windows ON AIR: source-owned native capture host (ba_native_stream.exe, WASAPI
%% loopback → AAC). Only format/control crosses its port; the same port protocol
%% as ba_mac_native_audio. The host app names the helper with
%% BA_WINDOWS_NATIVE_STREAM_HELPER; GStreamer and its plugins ship beside it.
-module(ba_windows_native_audio).
-behaviour(gen_server).
-export([start/1,stop/1,status/1,start_link/0,unavailable/0,helper/0,child_env/0]).
-export([init/1,handle_call/3,handle_cast/2,handle_info/2,terminate/2]).
-define(MICROPHONE,<<"Native microphone capture is not available yet.">>).
%% Native microphone capture does not exist yet (owner accepted the gap).
start(microphone) -> {error,native_microphone_unavailable};
start(broadcast) ->
    ok=ba_audio_sup:ensure_started(),
    case supervisor:start_child(ba_session_scope:ref(ba_audio_sup),#{id => ?MODULE,start => {?MODULE,start_link,[]},restart => temporary}) of
        {ok,P} -> gen_server:call(P,start);{error,{already_started,P}} -> gen_server:call(P,start);E -> E end.
stop(microphone) -> ok;
stop(broadcast) -> case ba_session_scope:whereis(?MODULE) of undefined -> ok;P -> gen_server:call(P,stop) end.
status(microphone) -> #{state => unsupported,error => ?MICROPHONE};
status(broadcast) -> case ba_session_scope:whereis(?MODULE) of undefined -> #{state => stopped};P -> gen_server:call(P,status) end.
unavailable() ->
    case helper() of
        false -> #{<<"microphone">> => ?MICROPHONE,<<"broadcast">> => <<"Sending sound from this Device is not available: its audio helper is missing.">>};
        _ -> #{<<"microphone">> => ?MICROPHONE}
    end.
%% The packaged helper, or false when this build has none.
helper() ->
    case ba_settings:env("BA_WINDOWS_NATIVE_STREAM_HELPER") of
        false -> false;
        Path -> case filelib:is_regular(Path) of true -> Path;false -> false end
    end.
start_link() -> gen_server:start_link(ba_session_scope:registration(?MODULE),?MODULE,[],[]).
init([]) -> process_flag(trap_exit,true),{ok,#{state => stopped}}.
handle_call(start,{Caller,_},#{state := stopped}=S) ->
    case ba_device_permission:enter(broadcast) of
        {ok,T} -> case helper() of
            false -> {reply,{error,native_stream_helper_missing},S};
            Helper ->
                [monitor(process,P) || P <- lists:usort([Caller]++
                    [P || Name <- [ba_device_config,ba_permission_pg],P <- [whereis(Name)],is_pid(P)]++
                    [P || Name <- [ba_session,ba_device_handler,ba_device_sup,ba_device_worker_sup],P <- [ba_session_scope:whereis(Name)],is_pid(P)])],
                %% Excluding BEAM's process tree keeps this Device's own playback
                %% (the receiving host is BEAM's child) out of what it sends.
                Port=open_port({spawn_executable,Helper},[binary,{packet,4},exit_status,use_stdio,hide,
                    {args,["--exclude-pid",os:getpid()]},{env,child_env()}]),
                erlang:send_after(250,self(),heartbeat),{reply,ok,S#{state := starting,port => Port,token => T}}
        end;
        E -> {reply,E,S}
    end;
handle_call(start,_,S) -> {reply,ok,S};
handle_call(status,_,S) -> {reply,maps:with([state,format,error],S),S};
handle_call(native_endpoint,_,#{endpoint := P}=S) -> {reply,{ok,P},S};
handle_call(stop,_,S) -> {R,N}=stop_native(S),{reply,R,N};
handle_call({revoke_permissions,_},_,S) -> {R,N}=stop_native(S),{reply,R,N};
handle_call(_,_,S) -> {reply,{error,native_endpoint_unavailable},S}.
handle_cast(_,S) -> {noreply,S}.
handle_info(heartbeat,#{port := Port,token := T}=S) ->
    case ba_device_permission:valid(broadcast,T) of
        true -> try true=port_command(Port,<<$h>>),erlang:send_after(250,self(),heartbeat),
                Next=case maps:find(source,S) of
                    {ok,Source} -> Clock=ba_session_clock:id(),
                        case Clock=:=maps:get(source_clock,S,Clock) of
                            true -> S;false -> ok=ba_audio:rebind(Source,Clock),S#{source_clock => Clock}
                        end;
                    error -> S
                end,
                {noreply,Next}
            catch _:_ -> {stop,native_capture_closed,S} end;
        false -> {stop,consent_revoked,S}
    end;
handle_info({Port,{data,<<9,P:16>>}},#{port := Port}=S) -> {noreply,S#{endpoint => P}};
handle_info({Port,{data,<<1,Rate:32/little,Channels:32/little>>}},#{port := Port}=S) when Rate>0,Channels>0 ->
    D=#{encoding => pcm,sample_format => float32_le,sample_rate => Rate,channel_count => Channels,
        clock => ba_session_clock:id(),stream_handler => native_gst_aac},
    case ba_audio:publish(#{source_key => <<"default-output">>,name => <<"Windows output — AAC 320 kb/s">>,profiles => #{channel => D}},self()) of
        {ok,Source} -> monitor(process,Source),
            {noreply,S#{state := running,source => Source,source_clock => maps:get(clock,D),format => #{rate => Rate,channels => Channels}}};
        E -> {stop,E,S}
    end;
handle_info({Port,{data,<<3,_Code:32/little-signed,Text/binary>>}},#{port := Port}=S) ->
    {noreply,S#{error => Text}};
handle_info({Port,{exit_status,Code}},#{port := Port}=S) ->
    case maps:find(source,S) of {ok,P} -> try ba_audio:unpublish(P) catch exit:_ -> ok end;error -> ok end,
    Error=maps:get(error,S,iolist_to_binary(io_lib:format("Native capture exited (~B); check the Windows output device.",[Code]))),
    {noreply,(maps:without([port,source,endpoint,token],S))#{state := error,error => Error}};
handle_info({'EXIT',Port,_},#{port := Port}=S) -> {stop,native_capture_closed,S};
handle_info({'DOWN',_,process,_,_},S) -> {stop,owner_down,S};
handle_info(_,S) -> {noreply,S}.
stop_native(#{port := Port}=S) ->
    R=ba_native_stop:port(Port,<<$s>>,<<6>>),
    case R of
        ok -> try port_close(Port) catch _:_ -> ok end,
            case maps:find(source,S) of {ok,P} -> try ba_audio:unpublish(P) catch exit:_ -> ok end;error -> ok end,
            {ok,#{state => stopped}};
        _ -> {R,S#{state := error,error => native_stop_unconfirmed}}
    end;
stop_native(_) -> {ok,#{state => stopped}}.
terminate(_,S) -> stop_native(S),ok.

%% DLLs sit beside the helper; plugins in its plugins folder. Another GStreamer
%% installation's variables must not add plugins to this one.
child_env() ->
    Dir=filename:nativename(filename:dirname(helper_path())),
    ba_native_env:without_secrets()++[
        {"PATH",Dir++";"++os:getenv("PATH","")},
        {"GST_PLUGIN_SYSTEM_PATH_1_0",filename:join(Dir,"plugins")},
        {"GST_PLUGIN_PATH",false},{"GST_PLUGIN_PATH_1_0",false},{"GST_PLUGIN_SYSTEM_PATH",false},
        {"GST_REGISTRY_1_0",registry()},
        %% No separate plugin scanner ships with the app.
        {"GST_REGISTRY_FORK","no"}].
helper_path() -> case helper() of false -> ba_settings:env("BA_WINDOWS_NATIVE_STREAM_HELPER","");P -> P end.
%% GStreamer's plugin cache must be writable, outside the installed app.
registry() ->
    case ba_settings:env("BA_STATE_DIR") of
        false -> filename:join(filename:basedir(user_cache,"BEAM-Audio"),"gstreamer-registry.bin");
        State -> filename:join(State,"gstreamer-registry.bin")
    end.
