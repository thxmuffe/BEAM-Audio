%% Source-owned native capture host: only format/control crosses its port.
-module(ba_mac_native_audio).
-behaviour(gen_server).
-export([start/1,stop/1,status/1,start_link/0]).
-export([init/1,handle_call/3,handle_cast/2,handle_info/2,terminate/2]).
start(microphone) -> ba_mac_audio:start(microphone);
start(broadcast) ->
    ok=ba_audio_sup:ensure_started(),
    case supervisor:start_child(ba_session_scope:ref(ba_audio_sup),#{id => ?MODULE,start => {?MODULE,start_link,[]},restart => temporary}) of
        {ok,P} -> gen_server:call(P,start);{error,{already_started,P}} -> gen_server:call(P,start);E -> E end.
stop(microphone) -> ba_mac_audio:stop(microphone);
stop(broadcast) -> case ba_session_scope:whereis(?MODULE) of undefined -> ok;P -> gen_server:call(P,stop) end.
status(microphone) -> ba_mac_audio:status(microphone);
status(broadcast) -> case ba_session_scope:whereis(?MODULE) of undefined -> #{state => stopped};P -> gen_server:call(P,status) end.
start_link() -> gen_server:start_link(ba_session_scope:registration(?MODULE),?MODULE,[],[]).
init([]) -> process_flag(trap_exit,true),{ok,#{state => stopped}}.
handle_call(start,{Caller,_},#{state := stopped}=S) ->
    case ba_device_permission:enter(broadcast) of
        {ok,T} -> case ba_settings:env("BA_MAC_NATIVE_STREAM_HELPER") of
            false -> {reply,{error,native_stream_helper_missing},S};
            Helper ->
                [monitor(process,P) || P <- lists:usort([Caller]++
                    [P || Name <- [ba_device_config,ba_permission_pg],P <- [whereis(Name)],is_pid(P)]++
                    [P || Name <- [ba_buffee,ba_device_handler,ba_device_sup,ba_device_worker_sup],P <- [ba_session_scope:whereis(Name)],is_pid(P)])],
                Port=open_port({spawn_executable,Helper},[binary,{packet,4},exit_status,{env,child_env()}]),
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
                    {ok,Source} -> Clock=ba_buffee_clock:id(),
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
handle_info({Port,{data,<<1,B/binary>>}},#{port := Port}=S) ->
    Format=ba_core_audio:format(B),
    D=#{encoding => pcm,sample_format => float32_le,sample_rate => maps:get(rate,Format),channel_count => maps:get(channels,Format),
        clock => ba_buffee_clock:id(),stream_handler => native_gst_aac},
    case ba_audio:publish(#{source_key => <<"default-output">>,name => <<"Mac output — AAC 320 kb/s (native trial)">>,profiles => #{channel => D}},self()) of
        {ok,Source} -> monitor(process,Source),{noreply,S#{state := running,source => Source,source_clock => maps:get(clock,D),format => Format}};E -> {stop,E,S} end;
handle_info({Port,{data,<<3,_Code:32/little-signed,Text/binary>>}},#{port := Port}=S) ->
    {noreply,S#{error => Text}};
handle_info({Port,{exit_status,Code}},#{port := Port}=S) ->
    case maps:find(source,S) of {ok,P} -> try ba_audio:unpublish(P) catch exit:_ -> ok end;error -> ok end,
    Error=maps:get(error,S,iolist_to_binary(io_lib:format("Native capture exited (~B); check capture permission and format.",[Code]))),
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

child_env() ->
    case ba_settings:env("BA_GSTREAMER_RUNTIME") of
        false -> ba_native_env:without_secrets();
        Runtime -> ba_native_env:without_secrets()++[
            {"DYLD_LIBRARY_PATH",filename:join(Runtime,"lib")},
            {"GST_PLUGIN_SYSTEM_PATH_1_0",filename:join(filename:dirname(Runtime),"plugins")},
            {"GST_REGISTRY_1_0",filename:join(filename:dirname(Runtime),"native-stream-registry.bin")}]
    end.
