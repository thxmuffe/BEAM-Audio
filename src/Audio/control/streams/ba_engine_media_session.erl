%% One subscription's media setup on the native engine; control only, never audio.
%%
%% The receiver speaks first: signal.endpoint carries its ephemeral X25519
%% public key and the ICE description of its engine connection. The provider
%% answers with signal.stream: its own ephemeral key, the stream's SRTP key
%% wrapped with the agreed secret (ECDH + HKDF-SHA256, ChaCha20-Poly1305), the
%% stream's SSRC and Session-time anchor, and its own ICE description. Both
%% messages travel signed through Session control, which the Reception can
%% read, so no key ever travels in the clear. One stream key per capture lets
%% the provider encrypt each packet once for every receiver.
%%
%% Connectivity is ICE (libjuice in the engine, see ba_audio_route): both
%% engines gather candidates (local, public via STUN, relayed via TURN), check
%% them and choose the path. When the receiver's network changes it starts a
%% new connection and announces it again (ICE restart); the provider follows,
%% and playback continues from the same buffer.
-module(ba_engine_media_session).
-behaviour(gen_server).
-export([start_link/1]).
-export([init/1,handle_call/3,handle_cast/2,handle_info/2,terminate/2,format_status/1]).
-export([wrap/3,unwrap/3]).

-define(HEARTBEAT,250).
-define(SETUP_TIMEOUT,15000).
-define(NETWORK_CHECK,2000).

start_link(Args) -> gen_server:start_link(?MODULE,Args,[]).

init(#{owner := Owner,role := Role,descriptor := D,attempt := Attempt,context := #{deadline := Deadline}}=Args) ->
    process_flag(trap_exit,true),
    %% A provider sends what its source captures: system audio or microphone.
    Permission=case Role of
        provider -> {ok,Kind}=gen_server:call(maps:get(source_pid,Args),{stream,kind},1000),Kind;
        receiver -> playback
    end,
    case ba_device_permission:enter(Permission) of
        {ok,Token} ->
            Watch=[Owner|[P || P <- [maps:get(source_pid,Args,undefined)],is_pid(P)]],
            [monitor(process,P) || P <- Watch],
            %% ba_audio_sup:start_media started the engine before this worker.
            Engine=ba_session_scope:whereis(ba_audio_engine),
            monitor(process,Engine),
            {Public,Private}=crypto:generate_key(ecdh,x25519),
            S=#{owner => Owner,role => Role,descriptor => D,attempt => Attempt,deadline => Deadline,
                permission => Permission,token => Token,engine => Engine,public => Public,private => Private,
                source => maps:get(source_pid,Args,undefined),open => false,gain => 0.0,path => none},
            erlang:send_after(?HEARTBEAT,self(),heartbeat),
            erlang:send_after(?SETUP_TIMEOUT,self(),setup_timeout),
            case Role of
                receiver ->
                    erlang:send_after(?NETWORK_CHECK,self(),network_check),
                    {ok,connect(S#{interfaces => ba_audio_route:interfaces()})};
                provider -> {ok,S}
            end;
        {error,R} -> {stop,R}
    end.

handle_call(status,_,S) ->
    {reply,#{open => maps:get(open,S),role => maps:get(role,S),native_payload_bypass => true,synchronized => true,
        codec => flac,setup => #{stage => case maps:get(open,S) of true -> open;false -> engine_negotiating end},
        stats => engine_stats(S)},S};
handle_call({output,Action},_,#{role := receiver}=S) when Action=:=play;Action=:=pause ->
    Gain=case Action of play -> 1.0;pause -> 0.0 end,
    case maps:find(ssrc,S) of
        {ok,Ssrc} -> {ok,_}=ba_audio_engine:command(maps:get(engine,S),#{op => volume,ssrc => Ssrc,gain => Gain});
        error -> ok
    end,
    {reply,ok,S#{gain := Gain}};
handle_call({revoke_permissions,_},_,S) -> {stop,normal,ok,S};
handle_call(_,_,S) -> {reply,{error,unsupported_engine_command},S}.

handle_cast({renew,Owner,Until},#{owner := Owner,deadline := Old}=S) when Until>Old -> {noreply,S#{deadline := Until}};
%% The receiver's connection (first, or new after a network change): answer
%% with a fresh connection of our own; the stream goes there once ICE connects.
handle_cast({signal,#{<<"kind">> := <<"signal.endpoint">>,<<"ice">> := Remote}=P},#{role := provider}=S) ->
    Next=connect(S#{endpoint => P}),
    {ok,_}=ba_audio_engine:command(maps:get(engine,Next),#{op => remote,conn => maps:get(conn,Next),description => Remote}),
    {noreply,Next};
handle_cast({signal,#{<<"kind">> := <<"signal.stream">>,<<"ice">> := Remote}=P},#{role := receiver,conn := Conn,engine := Engine}=S) ->
    {ok,_}=ba_audio_engine:command(Engine,#{op => remote,conn => Conn,description => Remote}),
    case maps:get(open,S) orelse maps:is_key(ssrc,S) of
        true -> {noreply,S};  % a new provider connection for a stream already playing
        false ->
            #{<<"public">> := Peer,<<"wrapped">> := Wrapped,<<"ssrc">> := Ssrc,<<"rate">> := Rate,<<"anchor_ns">> := Anchor}=P,
            Key=unwrap(binary:decode_hex(Wrapped),secret(binary:decode_hex(Peer),S),maps:get(attempt,S)),
            {noreply,start_speaker(S#{ssrc => Ssrc,key => Key,rate => Rate,anchor => binary_to_integer(Anchor)})}
    end;
handle_cast(_,S) -> {noreply,S}.

handle_info(heartbeat,S) ->
    case live(S) of
        false -> {stop,authorization_expired,S};
        true ->
            erlang:send_after(?HEARTBEAT,self(),heartbeat),
            {noreply,follow_delay(S)}
    end;
%% Our side of the connection is ready: send its description to the peer.
handle_info({ba_audio_engine,_,#{event := <<"ice_description">>,conn := Conn,description := Description}},#{conn := Conn}=S) ->
    {noreply,describe(Description,S)};
handle_info({ba_audio_engine,_,#{event := <<"ice_state">>,conn := Conn,state := State}=E},#{conn := Conn}=S) ->
    {noreply,ice_state(State,E,S)};
handle_info(network_check,#{role := receiver}=S) ->
    erlang:send_after(?NETWORK_CHECK,self(),network_check),
    {noreply,check_network(S)};
%% The OS reported a path change (iPhone): check now, not at the next poll.
handle_info(network_hint,#{role := receiver}=S) -> {noreply,check_network(S)};
handle_info(retry_speaker,#{open := false}=S) -> {noreply,start_speaker(S)};
handle_info(retry_provide,#{open := false,ice_local := Description}=S) -> {noreply,describe(Description,S)};
handle_info(setup_timeout,#{open := false}=S) -> {stop,engine_setup_timeout,S};
handle_info({'DOWN',_,process,Engine,_},#{engine := Engine}=S) -> {stop,audio_engine_down,maps:without([ssrc,conn],S)};
handle_info({'DOWN',_,process,_,_},S) -> {stop,owner_down,S};
handle_info(_,S) -> {noreply,S}.

terminate(_,#{engine := Engine}=S) ->
    case S of #{conn := Conn} -> try ba_audio_engine:command(Engine,#{op => disconnect,conn => Conn},1000) catch exit:_ -> ok end;_ -> ok end,
    case S of
        #{role := receiver,ssrc := Ssrc,open := true} ->
            try ba_audio_engine:command(Engine,#{op => stop_speaker,ssrc => Ssrc},1000) catch exit:_ -> ok end;
        _ -> ok
    end,ok;
terminate(_,_) -> ok.

format_status(Status) ->
    maps:map(fun(state,S) -> maps:with([role,open,ssrc,path],S);(log,_) -> [];(_,_) -> redacted end,Status).

%% ---- Connections ------------------------------------------------------------------
%% New addresses mean a new network: a new ICE connection (ICE restart).
check_network(S) ->
    Now=ba_audio_route:interfaces(),
    case Now=:=maps:get(interfaces,S) of
        true -> S;
        false -> logger:notice("Audio route: network changed; reconnecting"),connect(S#{interfaces := Now})
    end.

%% A new ICE connection replaces the previous one (first setup or ICE restart).
connect(#{engine := Engine}=S) ->
    case S of #{conn := Old} -> {ok,_}=ba_audio_engine:command(Engine,#{op => disconnect,conn => Old});_ -> ok end,
    Conn=erlang:unique_integer([positive]) band 16#7fffffff,
    {ok,_}=ba_audio_engine:command(Engine,(ba_audio_route:ice_config())#{op => connect,conn => Conn}),
    (maps:remove(ice_local,S))#{conn => Conn,path => none}.

describe(Description,#{role := receiver,owner := Owner,public := Public}=S) ->
    Owner ! {audio_signal,self(),#{<<"kind">> => <<"signal.endpoint">>,<<"public">> => binary:encode_hex(Public),
        <<"ice">> => Description}},
    S#{ice_local => Description};
describe(Description,#{role := provider,source := Source,attempt := Attempt,endpoint := #{<<"public">> := Peer}}=S) ->
    %% The capture's anchor is known once its first frames arrive: retry briefly.
    case gen_server:call(Source,{stream,describe},1000) of
        {ok,#{ssrc := Ssrc,key := StreamKey,anchor_ns := Anchor,rate := Rate}} ->
            Wrapped=wrap(StreamKey,secret(binary:decode_hex(Peer),S),Attempt),
            maps:get(owner,S) ! {audio_signal,self(),#{<<"kind">> => <<"signal.stream">>,
                <<"public">> => binary:encode_hex(maps:get(public,S)),<<"wrapped">> => binary:encode_hex(Wrapped),
                <<"ssrc">> => Ssrc,<<"rate">> => Rate,<<"anchor_ns">> => integer_to_binary(Anchor),<<"ice">> => Description}},
            S#{open := true,ssrc => Ssrc,ice_local => Description};
        {error,capture_starting} ->
            erlang:send_after(100,self(),retry_provide),S#{ice_local => Description}
    end.

%% ICE reports progress; once connected, the stream goes on this connection.
%% The path is the selected candidate pair: host (same network), srflx or prflx
%% (through NATs), relay (through TURN).
ice_state(State,E,#{conn := Conn}=S) when State=:= <<"connected">>;State=:= <<"completed">> ->
    Path=path(maps:get(local,E,<<"unknown">>),maps:get(remote,E,<<"unknown">>)),
    case maps:get(path,S) of
        Path -> S;
        _ ->
            logger:notice("Audio route: ICE ~ts via ~ts (~ts)",[State,Path,maps:get(remote_address,E,<<"?">>)]),
            case S of
                #{role := provider,source := Source} -> ok=gen_server:call(Source,{stream,{add_peers,self(),[Conn]}},1000);
                _ -> ok
            end,
            count(route_changes,S#{path := Path})
    end;
ice_state(<<"failed">>,_,S) ->
    logger:notice("Audio route: ICE failed"),count(ice_failures,S#{path := failed});
ice_state(_,_,S) -> S.
path(<<"relay">>,_) -> relay;
path(_,<<"relay">>) -> relay;
path(<<"host">>,<<"host">>) -> direct;
path(_,_) -> nat.
count(K,S) -> S#{K => maps:get(K,S,0)+1}.

%% ---- Receiver ---------------------------------------------------------------------
start_speaker(#{engine := Engine}=S) ->
    case ba_session_clock:presentation([]) of
        {ok,#{offset_ms := Delay}} ->
            C=#{op => start_speaker,ssrc => maps:get(ssrc,S),rate => maps:get(rate,S),anchor_ns => maps:get(anchor,S),
                delay_ms => Delay,key => maps:get(key,S),gain => maps:get(gain,S)},
            %% Starting the first speaker activates the OS audio session, which
            %% can take seconds on iPhone.
            case ba_audio_engine:command(Engine,C,15000) of
                {ok,_} -> maps:get(owner,S) ! {audio_transport,self(),open},S#{open := true,delay => Delay};
                {error,<<"clock mapping required",_/binary>>} -> erlang:send_after(?HEARTBEAT,self(),retry_speaker),S
            end;
        _ -> erlang:send_after(?HEARTBEAT,self(),retry_speaker),S
    end.

%% The Response time can change while playing: the speaker moves in place, so
%% the output device and the OS audio session stay open.
follow_delay(#{role := receiver,open := true,delay := Old,engine := Engine,ssrc := Ssrc}=S) ->
    case ba_session_clock:presentation([]) of
        {ok,#{offset_ms := New}} when New=/=Old ->
            {ok,_}=ba_audio_engine:command(Engine,#{op => delay,ssrc => Ssrc,delay_ms => New}),
            S#{delay := New};
        _ -> S
    end;
follow_delay(S) -> S.

%% ---- Keys -----------------------------------------------------------------------------
secret(PeerPublic,#{private := Private}) when byte_size(PeerPublic)=:=32 ->
    crypto:compute_key(ecdh,PeerPublic,Private,x25519).
%% HKDF-SHA256 (RFC 5869) from the X25519 secret, bound to this attempt.
kek(Secret,Attempt) ->
    Prk=crypto:mac(hmac,sha256,Attempt,Secret),
    crypto:mac(hmac,sha256,Prk,<<"ba engine stream key v1",1>>).
%% Each ephemeral key pair serves one attempt, so a zero nonce is never reused.
wrap(StreamKey,Secret,Attempt) ->
    {Cipher,Tag}=crypto:crypto_one_time_aead(chacha20_poly1305,kek(Secret,Attempt),<<0:96>>,StreamKey,Attempt,true),
    <<Cipher/binary,Tag/binary>>.
unwrap(<<Cipher:30/binary,Tag:16/binary>>,Secret,Attempt) ->
    case crypto:crypto_one_time_aead(chacha20_poly1305,kek(Secret,Attempt),<<0:96>>,Cipher,Attempt,Tag,false) of
        error -> error(stream_key_unwrap_failed);
        Key -> Key
    end.

%% ---- Helpers --------------------------------------------------------------------------
live(S) -> erlang:monotonic_time(millisecond)<maps:get(deadline,S) andalso
    ba_device_permission:valid(maps:get(permission,S),maps:get(token,S)).
%% The engine's own counters for this stream, as bounded integers for
%% diagnostics, with the path ICE chose. The scheduling error covers the time
%% since the previous read.
engine_stats(#{role := Role,open := true,engine := Engine}=S) ->
    try ba_audio_engine:command(Engine,#{op => status},500) of
        {ok,Status} -> maps:merge(stream_stats(Role,Status,S),path_stats(S));
        _ -> #{}
    catch exit:_ -> #{} end;
engine_stats(_) -> #{}.
path_stats(S) ->
    Path=maps:get(path,S),
    #{path_direct => flag(Path=:=direct),path_nat => flag(Path=:=nat),path_relay => flag(Path=:=relay),
      path_none => flag(Path=:=none orelse Path=:=failed),
      route_changes => maps:get(route_changes,S,0),ice_failures => maps:get(ice_failures,S,0)}.
flag(true) -> 1;
flag(false) -> 0.
stream_stats(receiver,#{speakers := Speakers},#{ssrc := Ssrc}) ->
    case [X || #{ssrc := I}=X <- Speakers,I=:=Ssrc] of
        [#{error := E}=X] -> (maps:with([packets,duplicates,late,early,rejected,missing_frames,jumps,nacks,recovered],X))#{
            schedule_error_max_us => round(maps:get(max_us,E)),schedule_error_mean_us => round(maps:get(mean_us,E))};
        [] -> #{}
    end;
stream_stats(provider,#{captures := Captures},#{ssrc := Ssrc}) ->
    case [C || #{ssrc := I}=C <- Captures,I=:=Ssrc] of
        [#{error := E}=C] ->
            #{capture => Ssrc,sent => maps:get(sent,C),send_errors => maps:get(send_errors,C),capture_overruns => maps:get(overruns,C),
              capture_jumps => maps:get(jumps,C),capture_error_max_us => round(maps:get(max_us,E)),retransmits => maps:get(retransmits,C)};
        [] -> #{}
    end;
stream_stats(_,_,_) -> #{}.
