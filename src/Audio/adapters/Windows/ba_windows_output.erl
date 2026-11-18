%% WASAPI binding (ba_audio_output.exe). Erlang supplies every deadline; the
%% helper places blocks at their targets and reports late ones, never retiming.
%% Same port protocol as ba_mac_output, plus <<5>> statistics for diagnostics.
-module(ba_windows_output).
-behaviour(gen_server).
-export([open/1,write/4,close/1,available/0,diagnostics/2]).
-export([init/1,handle_call/3,handle_cast/2,handle_info/2,terminate/2,format_status/1]).
available() -> case ba_settings:env("BA_WINDOWS_AUDIO_OUTPUT_HELPER") of false -> false;P -> filelib:is_regular(P) end.
open(D) -> case ba_device_permission:allowed(playback) of
    true -> permitted_open(D);false -> {error,consent_required} end.
write(D,T,F,PCM) -> case ba_device_permission:allowed(playback) of
    true -> permitted_write(D,T,F,PCM);false -> {error,consent_revoked} end.
permitted_open(#{sample_rate := Rate,channel_count := 2}) ->
    case available() of
        false -> {error,windows_output_helper_unavailable};
        true -> case gen_server:start_link(?MODULE,Rate,[]) of
            {ok,P} -> {ok,Clock}=gen_server:call(P,clock),{ok,Clock#{pid => P}};
            Error -> Error
        end
    end.
permitted_write(#{pid := P,host_offset := Offset},Mono,Frames,PCM) -> gen_server:call(P,{write,Mono+Offset,Frames,PCM},1000).
close(#{pid := P}) -> try gen_server:call(P,{revoke_permissions,[speaker]},4000) catch exit:_ -> {error,native_stop_unconfirmed} end.
%% Counters from the helper itself: accepted, played and late frames/blocks.
%% They prove software scheduling on the device timeline, not acoustic output.
diagnostics(#{pid := P},#{<<"analysis">> := true}) ->
    try gen_server:call(P,stats,300) catch exit:_ -> unsupported end;
diagnostics(_,_) -> {ok,#{supported => true,backend => wasapi}}.
init(Rate) ->
    case ba_device_permission:enter(playback) of
        {ok,Token} -> case init_permitted(Rate) of {ok,S} -> {ok,S#{permission_token => Token}};Error -> Error end;
        Error -> {stop,Error}
    end.
init_permitted(Rate) ->
    process_flag(trap_exit,true),
    Port=open_port({spawn_executable,ba_settings:env("BA_WINDOWS_AUDIO_OUTPUT_HELPER")},
        [binary,{packet,4},exit_status,use_stdio,hide,{env,ba_native_env:without_secrets()},{args,["output",integer_to_list(Rate)]}]),
    receive
        {Port,{data,<<1>>}} -> calibrate(Port);
        {Port,{data,<<3,_:32/little-signed,Error/binary>>}} -> port_close(Port),{stop,{native_output_open_failed,Error}};
        _ -> port_close(Port),{stop,native_output_open_failed}
    after 3000 -> port_close(Port),{stop,native_output_timeout} end.
calibrate(Port) ->
    %% Map the Erlang monotonic clock to the helper's QPC clock at the request
    %% midpoint. A platform clock binding, not Session clock policy.
    Sent=erlang:monotonic_time(nanosecond),true=port_command(Port,<<3>>),
    receive
        {Port,{data,<<3,Host:64,Latency:64>>}} ->
            Now=erlang:monotonic_time(nanosecond),
            {ok,#{port => Port,clock => #{host_offset => Host-(Sent+Now) div 2,latency_ns => Latency,
                mapping_round_trip_ns => Now-Sent}}};
        _ -> port_close(Port),{stop,native_output_clock_mapping_failed}
    after 1000 -> port_close(Port),{stop,native_output_clock_timeout} end.

handle_call({revoke_permissions,_},_,#{port := Port}=S) ->
    case ba_native_stop:port(Port,<<4>>,<<4>>) of
        ok -> {stop,normal,ok,S};Error -> {reply,Error,S}
    end;
handle_call(clock,_,S) -> {reply,{ok,maps:get(clock,S)},S};
handle_call(stats,_,#{port := Port}=S) ->
    true=port_command(Port,<<5>>),
    receive
        {Port,{data,<<5,Scheduled:64,Played:64,Silence:64,Late:32,Queued:32,Reanchors:32,Latency:64,Rate:32,Channels:32>>}} ->
            {reply,{ok,#{supported => true,backend => wasapi,engine_running => true,player_running => true,
                scheduled_frames => Scheduled,completed_frames => Played,silence_frames => Silence,
                rejected_buffers => Late,queued_buffers => Queued,clock_reanchors => Reanchors,
                latency_ns => Latency,sample_rate => Rate,channels => Channels}},S}
    after 250 -> {reply,unsupported,S} end;
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
    maps:map(fun(state,S) -> maps:with([kind],S);
        (log,_) -> [];(_,_) -> redacted end,Status).
