%% Supervised native RTP endpoint. Only control/signalling crosses this socket.
-module(ba_native_media_session).
-behaviour(gen_server).
-export([start_link/1,available/0]).
-export([init/1,handle_call/3,handle_cast/2,handle_info/2,terminate/2,format_status/1]).
%% The host app starts the native stream listener and names its port.
available() -> ba_settings:env("BA_NATIVE_STREAM_PORT")=/=false.
%% Every platform uses the same ICE servers: the configured STUN URLs.
ice_servers() -> [#{urls => ba_settings:app(direct_stun_urls,[])}].
start_link(Args) -> gen_server:start_link(?MODULE,Args,[]).
init(#{owner := Owner,role := Role,descriptor := D,context := #{deadline := Deadline}}=Args) ->
    process_flag(trap_exit,true),
    Permission=case Role of provider -> broadcast;receiver -> playback end,
    case ba_device_permission:enter(Permission) of
        {ok,Token} ->
            Owners=[Owner|case maps:find(source_pid,Args) of {ok,P} -> [P];error -> [] end]++
                [P || Name <- [ba_device_config,ba_permission_pg],P <- [whereis(Name)],is_pid(P)]++
                [P || Name <- [ba_buffee,ba_buffee_control,ba_device_handler,ba_device_sup,ba_device_worker_sup],P <- [ba_session_scope:whereis(Name)],is_pid(P)],
            [monitor(process,P) || P <- lists:usort(Owners)],
            Port=case Role of
                provider -> {ok,P0}=gen_server:call(maps:get(source_pid,Args),native_endpoint,1000),P0;
                receiver -> list_to_integer(ba_settings:env("BA_NATIVE_STREAM_PORT"))
            end,
            G=binary:encode_hex(crypto:strong_rand_bytes(16)),
            case connect(Port,G,D) of
                {ok,Socket,Clock} ->
                    true=ba_device_permission:valid(Permission,Token),
                    ok=send(Socket,G,#{op => <<"prepare">>,role => atom_to_binary(Role),rate => maps:get(sample_rate,D),
                        channels => maps:get(channel_count,D),ice_servers => ice_servers(),buffer_ms => maps:get(offset_ms,Clock)}),
                    ok=inet:setopts(Socket,[{active,once}]),
                    erlang:send_after(250,self(),heartbeat),erlang:send_after(10000,self(),setup_timeout),
                    {ok,Args#{socket => Socket,generation => G,permission => Permission,token => Token,
                        open => false,playing => false,deadline => Deadline,stats => #{},clock => Clock}};
                Error -> {stop,Error}
            end;
        {error,R} -> {stop,R}
    end.
connect(Port,G,D) ->
    case gen_tcp:connect({127,0,0,1},Port,[binary,{packet,4},{active,false},{nodelay,true},{packet_size,131072},
            {send_timeout,1000},{send_timeout_close,true}],2000) of
        {ok,S} ->
            Result=try
                ok=send(S,G,#{op => <<"hello">>,version => 2}),{ok,B}=gen_tcp:recv(S,0,1000),
                #{<<"event">> := <<"hello">>,<<"version">> := 2,<<"generation">> := G,
                  <<"profile">> := <<"gst_aac_rtp_v2">>,<<"owner_loss_stop">> := true,<<"stop_ack">> := true,<<"schedule">> := true}=json:decode(B),
                Probes=[probe(S,G,D) || _ <- lists:seq(1,5)],
                [{_,Plan,Clock}|_]=lists:sort(Probes),ok=send(S,G,Plan),{ok,S,Clock}
            catch throw:{native_clock_mapping_failed,_}=Reason -> {error,Reason};
                  _:_ -> {error,native_lifecycle_handshake_failed} end,
            case Result of {ok,S,_} -> Result;_ -> gen_tcp:close(S),Result end;
        Error -> Error
    end.
probe(S,G,D) ->
    Sent=erlang:monotonic_time(nanosecond),
    ok=send(S,G,#{op => <<"clock">>,sent_ns => integer_to_binary(Sent)}),
    {ok,B}=gen_tcp:recv(S,0,1000),Received=erlang:monotonic_time(nanosecond),
    #{<<"event">> := <<"clock">>,<<"generation">> := G}=E=json:decode(B),
    case ba_audio_native_clock:plan(E,Sent,Received,D,#{}) of
        {ok,Plan,Meta} -> {Received-Sent,Plan,Meta};
        {error,Reason} -> throw({native_clock_mapping_failed,Reason})
    end.
handle_call(status,_,S) ->
    {reply,#{open => maps:get(open,S),role => maps:get(role,S),native_payload_bypass => true,
        synchronized => false,codec => aac_lc,bitrate => 320000,stats => maps:get(stats,S),clock => maps:get(clock,S),
        setup => #{stage => case maps:get(open,S) of true -> open;false -> native_negotiating end}},S};
handle_call({output,Action},_,S) when Action=:=play;Action=:=pause ->
    case live(S) of
        true -> {reply,command(#{op => atom_to_binary(Action)},S),S#{playing := Action=:=play}};
        false -> {stop,authorization_expired,{error,consent_revoked},S}
    end;
handle_call({gain,G},_,S) when is_number(G),G>=0,G=<1 -> {reply,command(#{op => <<"gain">>,gain => G},S),S};
handle_call({revoke_permissions,_},_,S) -> Result=stop_native(S),{stop,normal,Result,S#{stopped => true}};
handle_call(_,_,S) -> {reply,{error,unsupported_native_command},S}.
handle_cast({renew,Owner,Until},#{owner := Owner,deadline := Old}=S) when Until>Old ->
    case now_ms()<Old of true -> {noreply,S#{deadline := Until}};false -> {stop,authorization_expired,S} end;
handle_cast({signal,#{<<"kind">> := Kind}=P},S) ->
    case live(S) of
        false -> {stop,authorization_expired,S};
        true ->
            C=case Kind of
                <<"signal.offer">> -> #{op => <<"offer">>,sdp => maps:get(<<"sdp">>,P)};
                <<"signal.answer">> -> #{op => <<"answer">>,sdp => maps:get(<<"sdp">>,P)};
                <<"signal.candidate">> -> #{op => <<"candidate">>,candidate => maps:get(<<"candidate">>,P),mid => maps:get(<<"mid">>,P),line => maps:get(<<"line">>,P)}
            end,
            case command(C,S) of ok -> {noreply,S};_ -> {stop,native_control_failed,S} end
    end;
handle_cast(_,S) -> {noreply,S}.
handle_info(heartbeat,S) ->
    case live(S) of
        false -> {stop,authorization_expired,S};
        true -> erlang:send_after(250,self(),heartbeat),
            Count=maps:get(heartbeats,S,0)+1,
            Updated=case Count rem 20 of
                0 -> Sent=erlang:monotonic_time(nanosecond),command(#{op => <<"clock">>,sent_ns => integer_to_binary(Sent)},S),S#{clock_request => Sent};
                _ -> S
            end,
            case Count rem 4 of 0 -> command(#{op => <<"stats">>},S);_ -> ok end,
            case command(#{op => <<"heartbeat">>},S) of ok -> {noreply,Updated#{heartbeats => Count}};_ -> {stop,native_control_failed,S} end
    end;
handle_info({tcp,Socket,B},#{socket := Socket,generation := G}=S) ->
    try true=live(S),#{<<"generation">> := G}=E=json:decode(B),ok=inet:setopts(Socket,[{active,once}]),native_event(E,S)
    catch _:_ -> {stop,invalid_native_event,S} end;
handle_info({tcp_closed,Socket},#{socket := Socket}=S) -> {stop,native_endpoint_closed,S};
handle_info({tcp_error,Socket,_},#{socket := Socket}=S) -> {stop,native_endpoint_failed,S};
handle_info({'DOWN',_,process,_,_},S) -> {stop,owner_down,S};
handle_info(setup_timeout,#{open := false}=S) -> {stop,native_setup_timeout,S};
handle_info(_,S) -> {noreply,S}.
native_event(#{<<"event">> := <<"clock">>,<<"sent_ns">> := Text}=E,#{clock_request := Sent}=S) ->
    case Text=:=integer_to_binary(Sent) of
        false -> {stop,invalid_native_clock_reply,S};
        true -> case ba_audio_native_clock:plan(E,Sent,erlang:monotonic_time(nanosecond),maps:get(descriptor,S),maps:get(clock,S)) of
            {ok,Plan,Clock} -> ok=command(Plan,S),{noreply,maps:remove(clock_request,S#{clock := Clock})};
            {error,R} -> {stop,R,S}
        end
    end;
native_event(#{<<"event">> := Kind}=E,S) when Kind=:= <<"offer">>;Kind=:= <<"answer">> ->
    maps:get(owner,S) ! {audio_signal,self(),#{<<"kind">> => <<"signal.",Kind/binary>>,<<"sdp">> => maps:get(<<"sdp">>,E)}},{noreply,S};
native_event(#{<<"event">> := <<"candidate">>}=E,S) ->
    maps:get(owner,S) ! {audio_signal,self(),#{<<"kind">> => <<"signal.candidate">>,<<"candidate">> => maps:get(<<"candidate">>,E),
        <<"mid">> => maps:get(<<"mid">>,E),<<"line">> => maps:get(<<"line">>,E)}},{noreply,S};
native_event(#{<<"event">> := <<"connected">>},S) -> maps:get(owner,S) ! {audio_transport,self(),open},{noreply,S#{open := true}};
native_event(#{<<"event">> := <<"stats">>}=E,S) ->
    Count=maps:get(stat_samples,S,0)+1,
    case Count rem 5=:=0 andalso ba_audio_diagnostics:enabled(analysis) of
        true ->
            Summary=maps:with([<<"frames">>,<<"dropped">>,<<"rtcp_mapped_packets">>,<<"unmapped_packets">>,
                <<"sink_rendered_buffers">>,<<"sink_dropped_buffers">>,<<"capture_clock_skew_ns">>,<<"correction_ppm">>,
                <<"jitter_buffer_ms">>,<<"render_delay_ns">>],E),
            logger:notice("Native ~p timing: ~p",[maps:get(role,S),Summary]);
        false -> ok
    end,
    {noreply,S#{stats := E,stat_samples => Count}};
native_event(#{<<"event">> := <<"error">>,<<"error">> := R},S) -> {stop,{native_media,R},S};
native_event(_,S) -> {noreply,S}.
live(S) -> now_ms()<maps:get(deadline,S) andalso ba_device_permission:valid(maps:get(permission,S),maps:get(token,S)) andalso ba_audio_native_clock:ready().
command(C,#{socket := Socket,generation := G}) -> send(Socket,G,C).
send(Socket,G,C) -> gen_tcp:send(Socket,json:encode(C#{generation => G})).
stop_native(#{socket := Socket,generation := G}) ->
    Id=erlang:unique_integer([positive]),
    try ok=inet:setopts(Socket,[{active,false}]),ok=send(Socket,G,#{op => <<"stop">>,request_id => Id}),await_stop(Socket,G,Id,now_ms()+1500)
    catch _:_ -> {error,native_stop_unconfirmed} end.
await_stop(Socket,G,Id,Deadline) ->
    case gen_tcp:recv(Socket,0,max(1,Deadline-now_ms())) of
        {ok,B} -> case json:decode(B) of
            #{<<"event">> := <<"stopped">>,<<"generation">> := G,<<"request_id">> := Id} -> ok;
            _ -> case now_ms()<Deadline of true -> await_stop(Socket,G,Id,Deadline);false -> {error,native_stop_timeout} end
        end;
        _ -> {error,native_stop_unconfirmed}
    end.
terminate(_,S) -> case maps:get(stopped,S,false) of true -> ok;false -> stop_native(S) end,gen_tcp:close(maps:get(socket,S)).
format_status(Status) -> maps:map(fun(state,S) -> maps:with([role,open,playing,stats],S);(log,_) -> [];(_,_) -> redacted end,Status).
now_ms() -> erlang:monotonic_time(millisecond).
