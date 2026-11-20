%% One subscription's media setup on the native engine; control only, never audio.
%%
%% The receiver speaks first: signal.endpoint carries its ephemeral X25519
%% public key and the UDP addresses of its engine. The provider answers with
%% signal.stream: its own ephemeral key, the stream's SRTP key wrapped with the
%% agreed secret (ECDH + HKDF-SHA256, ChaCha20-Poly1305), and the stream's SSRC
%% and Session-time anchor. Both messages travel signed through Session
%% control, which the Reception can read, so no key ever travels in the clear.
%% One stream key per capture lets the provider encrypt each packet once for
%% every receiver.
%%
%% Routing: the provider sends the stream only to an address that answered a
%% connectivity probe (a token the receiving engine echoes). Both sides list
%% their local and public (STUN) addresses; the receiver also probes the
%% provider, which opens its own NAT towards it (hole punching), and keeps
%% doing so to hold the path open. Those punch probes carry a token derived
%% from the attempt, so the provider also learns the address they really come
%% from (a peer-reflexive candidate) and streams there: behind carrier NAT that
%% is often the only address that works. The receiver announces its addresses again
%% when they change; the provider probes again and re-routes, and playback
%% continues from the same buffer. No relay yet (owner 2026-11-20).
-module(ba_engine_media_session).
-behaviour(gen_server).
-export([start_link/1]).
-export([init/1,handle_call/3,handle_cast/2,handle_info/2,terminate/2,format_status/1]).
-export([wrap/3,unwrap/3]).

-define(HEARTBEAT,250).
-define(SETUP_TIMEOUT,10000).
-define(PROBE_INTERVAL,500).
-define(ADDRESS_CHECK,2000).
-define(PUNCH_INTERVAL,2000).

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
                source => maps:get(source_pid,Args,undefined),open => false,gain => 0.0},
            erlang:send_after(?HEARTBEAT,self(),heartbeat),
            erlang:send_after(?SETUP_TIMEOUT,self(),setup_timeout),
            case Role of
                receiver -> erlang:send_after(?ADDRESS_CHECK,self(),address_check),{ok,announce(S)};
                provider -> ok=ba_audio_engine:listen(Engine,punch_token(Attempt)),{ok,S}
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
%% Every endpoint (the first, or new addresses later) is probed; the stream's
%% keys are sent once.
handle_cast({signal,#{<<"kind">> := <<"signal.endpoint">>}=P},#{role := provider}=S) ->
    Probing=probe(P,S),
    {noreply,case maps:get(open,S) of false -> provide(P,Probing);true -> Probing end};
handle_cast({signal,#{<<"kind">> := <<"signal.stream">>}=P},#{role := receiver,open := false}=S) ->
    #{<<"public">> := Peer,<<"wrapped">> := Wrapped,<<"ssrc">> := Ssrc,<<"rate">> := Rate,<<"anchor_ns">> := Anchor,
      <<"addresses">> := Addresses}=P,
    Key=unwrap(binary:decode_hex(Wrapped),secret(binary:decode_hex(Peer),S),maps:get(attempt,S)),
    self() ! punch,
    {noreply,start_speaker(S#{ssrc => Ssrc,key => Key,rate => Rate,anchor => binary_to_integer(Anchor),
        provider => ba_audio_stream_protocol:addresses(Addresses)})};
handle_cast(_,S) -> {noreply,S}.

handle_info(heartbeat,S) ->
    case live(S) of
        false -> {stop,authorization_expired,S};
        true ->
            erlang:send_after(?HEARTBEAT,self(),heartbeat),
            {noreply,follow_delay(S)}
    end;
handle_info(address_check,#{role := receiver}=S) ->
    erlang:send_after(?ADDRESS_CHECK,self(),address_check),
    {noreply,case addresses(S)=:=maps:get(addresses,S) of true -> S;false -> announce(S) end};
%% Outbound probes open this side's NAT towards the provider and keep it open.
handle_info(punch,#{role := receiver,engine := Engine,provider := Peers,attempt := Attempt}=S) ->
    erlang:send_after(?PUNCH_INTERVAL,self(),punch),
    {ok,_}=ba_audio_engine:command(Engine,#{op => probe,token => punch_token(Attempt),peers => Peers}),
    {noreply,S};
%% The receiver's punch arrived: stream to where it came from, and follow it.
handle_info({ba_audio_engine,_,#{event := <<"probe_seen">>,host := Host,port := Port}},#{role := provider,source := Source}=S) ->
    case maps:get(route,S,undefined) of
        [Host,Port] -> {noreply,S};
        _ -> ok=gen_server:call(Source,{stream,{add_peers,self(),[[Host,Port]]}},1000),
             {noreply,maps:remove(probe,S#{route => [Host,Port]})}
    end;
handle_info({reprobe,Token},#{probe := Token}=S) ->
    probe_send(S),erlang:send_after(?PROBE_INTERVAL,self(),{reprobe,Token}),{noreply,S};
handle_info({ba_audio_engine,_,#{event := <<"probe_reply">>,token := Token,host := Host,port := Port}},#{probe := Token,source := Source}=S) ->
    %% The first address that answered carries the stream to this receiver.
    ok=gen_server:call(Source,{stream,{add_peers,self(),[[Host,Port]]}},1000),
    {noreply,maps:remove(probe,S#{route => [Host,Port]})};
handle_info(retry_speaker,#{open := false}=S) -> {noreply,start_speaker(S)};
handle_info(retry_provide,#{open := false,endpoint := P}=S) -> {noreply,provide(P,S)};
handle_info(setup_timeout,#{open := false}=S) -> {stop,engine_setup_timeout,S};
handle_info({'DOWN',_,process,Engine,_},#{engine := Engine}=S) -> {stop,audio_engine_down,maps:remove(ssrc,S)};
handle_info({'DOWN',_,process,_,_},S) -> {stop,owner_down,S};
handle_info(_,S) -> {noreply,S}.

terminate(_,#{role := receiver,ssrc := Ssrc,engine := Engine,open := true}) ->
    try ba_audio_engine:command(Engine,#{op => stop_speaker,ssrc => Ssrc},1000) catch exit:_ -> ok end,ok;
terminate(_,_) -> ok.

format_status(Status) ->
    maps:map(fun(state,S) -> maps:with([role,open,ssrc],S);(log,_) -> [];(_,_) -> redacted end,Status).

%% ---- Provider ---------------------------------------------------------------------
%% The capture may still be starting; its anchor is known once the first frames
%% arrive, so retry briefly.
provide(#{<<"public">> := Peer}=P,#{source := Source,attempt := Attempt}=S) ->
    case gen_server:call(Source,{stream,describe},1000) of
        {ok,#{ssrc := Ssrc,key := StreamKey,anchor_ns := Anchor,rate := Rate}} ->
            Wrapped=wrap(StreamKey,secret(binary:decode_hex(Peer),S),Attempt),
            maps:get(owner,S) ! {audio_signal,self(),#{<<"kind">> => <<"signal.stream">>,
                <<"public">> => binary:encode_hex(maps:get(public,S)),<<"wrapped">> => binary:encode_hex(Wrapped),
                <<"ssrc">> => Ssrc,<<"rate">> => Rate,<<"anchor_ns">> => integer_to_binary(Anchor),
                <<"addresses">> => addresses(S)}},
            S#{open := true,ssrc => Ssrc};
        {error,capture_starting} ->
            erlang:send_after(100,self(),retry_provide),S#{endpoint => P}
    end.

%% A fresh token per endpoint; the engine probes every address until one answers.
probe(#{<<"addresses">> := Addresses},S) ->
    Token=crypto:strong_rand_bytes(16),
    Next=S#{probe => Token,candidates => ba_audio_stream_protocol:addresses(Addresses)},
    probe_send(Next),erlang:send_after(?PROBE_INTERVAL,self(),{reprobe,Token}),
    Next.
probe_send(#{engine := Engine,probe := Token,candidates := Peers}) ->
    {ok,_}=ba_audio_engine:command(Engine,#{op => probe,token => Token,peers => Peers}),ok.

%% ---- Receiver ---------------------------------------------------------------------
%% This Device's engine on its current addresses; sent again when they change.
announce(#{owner := Owner,public := Public}=S) ->
    Addresses=addresses(S),
    Owner ! {audio_signal,self(),#{<<"kind">> => <<"signal.endpoint">>,<<"public">> => binary:encode_hex(Public),
        <<"addresses">> => Addresses}},
    S#{addresses => Addresses}.
%% Plays at the Session's Response time; the engine needs its clock mapping first.
start_speaker(#{engine := Engine}=S) ->
    case ba_session_clock:presentation([]) of
        {ok,#{offset_ms := Delay}} ->
            C=#{op => start_speaker,ssrc => maps:get(ssrc,S),rate => maps:get(rate,S),anchor_ns => maps:get(anchor,S),
                delay_ms => Delay,key => maps:get(key,S),gain => maps:get(gain,S)},
            case ba_audio_engine:command(Engine,C) of
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

%% ---- Keys and addresses -------------------------------------------------------------
%% Both sides know the attempt, so the receiver's punch probes need no exchange.
punch_token(Attempt) -> binary:part(crypto:hash(sha256,[<<"ba punch v1">>,Attempt]),0,16).
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

%% This Device's engine: its port on each usable interface, then its public
%% (STUN) address, then loopback (other Devices on this machine).
addresses(#{engine := Engine}) ->
    Port=ba_audio_engine:udp_port(Engine),
    Local=[[H,Port] || H <- lists:sublist(hosts(),6)],
    Pairs=Local++(ba_audio_engine:mapped(Engine)--Local)++[[<<"127.0.0.1">>,Port]],
    iolist_to_binary(lists:join(<<" ">>,[[H,"/",integer_to_binary(P)] || [H,P] <- lists:sublist(Pairs,8)])).
hosts() ->
    {ok,Interfaces}=inet:getifaddrs(),
    Addresses=[A || {_,Options} <- Interfaces,lists:member(up,proplists:get_value(flags,Options,[])),
        lists:member(running,proplists:get_value(flags,Options,[])),
        {addr,A} <- Options,usable(A)],
    lists:usort([list_to_binary(inet:ntoa(A)) || A <- Addresses]).
usable({127,_,_,_}) -> false;
usable({169,254,_,_}) -> false;
usable({_,_,_,_}) -> true;
usable({16#fe80,_,_,_,_,_,_,_}) -> false;
usable({0,0,0,0,0,0,0,1}) -> false;
usable({_,_,_,_,_,_,_,_}) -> true.

%% ---- Helpers --------------------------------------------------------------------------
live(S) -> erlang:monotonic_time(millisecond)<maps:get(deadline,S) andalso
    ba_device_permission:valid(maps:get(permission,S),maps:get(token,S)).
%% The engine's own counters for this stream, as bounded integers for
%% diagnostics. The scheduling error covers the time since the previous read.
engine_stats(#{role := Role,open := true,engine := Engine}=S) ->
    try ba_audio_engine:command(Engine,#{op => status},500) of
        {ok,Status} -> stream_stats(Role,Status,S);
        _ -> #{}
    catch exit:_ -> #{} end;
engine_stats(_) -> #{}.
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
              capture_jumps => maps:get(jumps,C),capture_error_max_us => round(maps:get(max_us,E)),
              retransmits => maps:get(retransmits,C)};
        [] -> #{}
    end;
stream_stats(_,_,_) -> #{}.
