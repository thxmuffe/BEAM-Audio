%% AVAudioEngine binding. Erlang supplies every deadline; no adaptive retiming.
-module(ba_mac_output).
-behaviour(gen_server).
-export([open/1,write/4,close/1,available/0]).
-export([init/1,handle_call/3,handle_cast/2,handle_info/2,terminate/2,format_status/1]).
available() -> case os:getenv("BA_MAC_DEVICE_AUDIO_HELPER") of false -> false;P -> filelib:is_regular(P) end.
open(D) -> case ba_device_permission:allowed(playback) of
    true -> permitted_open(D);false -> {error,consent_required} end.
write(D,T,F,PCM) -> case ba_device_permission:allowed(playback) of
    true -> permitted_write(D,T,F,PCM);false -> {error,consent_revoked} end.
permitted_open(#{sample_rate := Rate,channel_count := 2}) ->
    case available() of
        false -> {error,mac_output_helper_unavailable};
        true -> case gen_server:start_link(?MODULE,Rate,[]) of
            {ok,P} -> {ok,Clock}=gen_server:call(P,clock),{ok,Clock#{pid => P}};
            Error -> Error
        end
    end.
permitted_write(#{pid := P,host_offset := Offset},Mono,Frames,PCM) -> gen_server:call(P,{write,Mono+Offset,Frames,PCM},1000).
close(#{pid := P}) -> try gen_server:call(P,{revoke_permissions,[speaker]},2000) catch exit:_ -> {error,native_stop_unconfirmed} end.
init(Rate) ->
    case ba_device_permission:enter(playback) of
        {ok,Token} -> case init_permitted(Rate) of {ok,S} -> {ok,S#{permission_token => Token}};Error -> Error end;
        Error -> {stop,Error}
    end.
init_permitted(Rate) ->
    process_flag(trap_exit,true),
    Port=open_port({spawn_executable,os:getenv("BA_MAC_DEVICE_AUDIO_HELPER")},
        [binary,{packet,4},exit_status,use_stdio,{env,ba_native_env:without_secrets()},{args,["output",integer_to_list(Rate)]}]),
    receive
        {Port,{data,<<1>>}} -> calibrate(Port);
        {Port,{data,<<3,_:32/little-signed,Error/binary>>}} -> port_close(Port),{stop,{native_output_open_failed,Error}};
        _ -> port_close(Port),{stop,native_output_open_failed}
    after 3000 -> port_close(Port),{stop,native_output_timeout} end.
calibrate(Port) ->
    %% Map clocks only after engine startup, so startup latency cannot bias the
    %% request midpoint. This is a platform clock binding, not Buffee clock policy.
    Sent=erlang:monotonic_time(nanosecond),true=port_command(Port,<<3>>),
    receive
        {Port,{data,<<3,Host:64,Latency:64>>}} ->
            Now=erlang:monotonic_time(nanosecond),
            {ok,#{port => Port,clock => #{host_offset => Host-(Sent+Now) div 2,latency_ns => Latency}}};
        _ -> port_close(Port),{stop,native_output_clock_mapping_failed}
    after 1000 -> port_close(Port),{stop,native_output_clock_timeout} end.

handle_call({revoke_permissions,_},_,#{port := Port}=S) ->
    case ba_native_stop:port(Port,<<4>>,<<4>>) of
        ok -> {stop,normal,ok,S};Error -> {reply,Error,S}
    end;
handle_call(clock,_,S) -> {reply,{ok,maps:get(clock,S)},S};
handle_call({write,Target,Frames,PCM},_,#{port := Port}=S) ->
    case ba_device_permission:valid(playback,maps:get(permission_token,S)) andalso erlang:port_info(Port,queue_size) of
        {queue_size,N} when N<1048576 ->
            {reply,case port_command(Port,<<2,Target:64,Frames:32,PCM/binary>>,[nosuspend]) of true -> ok;false -> {error,native_output_overloaded} end,S};
        _ -> {reply,{error,native_output_overloaded},S}
    end.
handle_cast(_,S) -> {noreply,S}.
handle_info({Port,{data,<<3,_:32/little-signed,Error/binary>>}},#{port := Port}=S) -> {stop,{native_output_failed,Error},S};
handle_info({Port,{exit_status,Code}},#{port := Port}=S) -> {stop,{native_output_exit,Code},S};
handle_info(_,S) -> {noreply,S}.
terminate(_,#{port := Port}) -> try port_close(Port) catch error:badarg -> ok end.

format_status(Status) ->
    maps:map(fun(state,S) -> maps:with([kind,dropped_callbacks],S);
        (log,_) -> [];(_,_) -> redacted end,Status).
