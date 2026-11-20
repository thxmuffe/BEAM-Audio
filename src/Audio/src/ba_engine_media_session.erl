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
-module(ba_engine_media_session).
-behaviour(gen_server).
-export([start_link/1]).
-export([init/1,handle_call/3,handle_cast/2,handle_info/2,terminate/2,format_status/1]).
-export([wrap/3,unwrap/3]).

-define(HEARTBEAT,250).
-define(SETUP_TIMEOUT,10000).

start_link(Args) -> gen_server:start_link(?MODULE,Args,[]).

init(#{owner := Owner,role := Role,descriptor := D,attempt := Attempt,context := #{deadline := Deadline}}=Args) ->
    process_flag(trap_exit,true),
    Permission=case Role of provider -> broadcast;receiver -> playback end,
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
                receiver ->
                    Owner ! {audio_signal,self(),#{<<"kind">> => <<"signal.endpoint">>,
                        <<"public">> => binary:encode_hex(Public),<<"hosts">> => hosts(),
                        <<"port">> => ba_audio_engine:udp_port(Engine)}};
                provider -> ok
            end,
            {ok,S};
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
handle_cast({signal,#{<<"kind">> := <<"signal.endpoint">>}=P},#{role := provider,open := false}=S) -> {noreply,provide(P,S)};
handle_cast({signal,#{<<"kind">> := <<"signal.stream">>}=P},#{role := receiver,open := false}=S) ->
    #{<<"public">> := Peer,<<"wrapped">> := Wrapped,<<"ssrc">> := Ssrc,<<"rate">> := Rate,<<"anchor_ns">> := Anchor}=P,
    Key=unwrap(binary:decode_hex(Wrapped),secret(binary:decode_hex(Peer),S),maps:get(attempt,S)),
    {noreply,start_speaker(S#{ssrc => Ssrc,key => Key,rate => Rate,anchor => binary_to_integer(Anchor)})};
handle_cast(_,S) -> {noreply,S}.

handle_info(heartbeat,S) ->
    case live(S) of
        false -> {stop,authorization_expired,S};
        true ->
            erlang:send_after(?HEARTBEAT,self(),heartbeat),
            {noreply,follow_delay(S)}
    end;
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
provide(#{<<"public">> := Peer,<<"hosts">> := Hosts,<<"port">> := Port}=P,#{source := Source,attempt := Attempt}=S) ->
    case gen_server:call(Source,{stream,describe},1000) of
        {ok,#{ssrc := Ssrc,key := StreamKey,anchor_ns := Anchor,rate := Rate}} ->
            Peers=[[H,Port] || H <- ba_audio_stream_protocol:hosts(Hosts)],
            ok=gen_server:call(Source,{stream,{add_peers,self(),Peers}},1000),
            Wrapped=wrap(StreamKey,secret(binary:decode_hex(Peer),S),Attempt),
            maps:get(owner,S) ! {audio_signal,self(),#{<<"kind">> => <<"signal.stream">>,
                <<"public">> => binary:encode_hex(maps:get(public,S)),<<"wrapped">> => binary:encode_hex(Wrapped),
                <<"ssrc">> => Ssrc,<<"rate">> => Rate,<<"anchor_ns">> => integer_to_binary(Anchor)}},
            S#{open := true};
        {error,capture_starting} ->
            erlang:send_after(100,self(),retry_provide),S#{endpoint => P}
    end.

%% ---- Receiver ---------------------------------------------------------------------
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

%% This Device's addresses on each usable interface. Without connectivity checks
%% (milestone 2) the provider sends to all; duplicates are dropped by SRTP.
hosts() ->
    {ok,Interfaces}=inet:getifaddrs(),
    Addresses=[A || {_,Options} <- Interfaces,lists:member(up,proplists:get_value(flags,Options,[])),
        lists:member(running,proplists:get_value(flags,Options,[])),
        {addr,A} <- Options,usable(A)],
    Hosts=lists:usort([list_to_binary(inet:ntoa(A)) || A <- Addresses]),
    iolist_to_binary(lists:join(<<" ">>,lists:sublist(Hosts,7)++[<<"127.0.0.1">>])).
usable({127,_,_,_}) -> false;
usable({169,254,_,_}) -> false;
usable({_,_,_,_}) -> true;
usable({16#fe80,_,_,_,_,_,_,_}) -> false;
usable({0,0,0,0,0,0,0,1}) -> false;
usable({_,_,_,_,_,_,_,_}) -> true.

%% ---- Helpers --------------------------------------------------------------------------
live(S) -> erlang:monotonic_time(millisecond)<maps:get(deadline,S) andalso
    ba_device_permission:valid(maps:get(permission,S),maps:get(token,S)).
engine_stats(#{role := receiver,open := true,engine := Engine,ssrc := Ssrc}) ->
    try ba_audio_engine:command(Engine,#{op => status},500) of
        {ok,#{speakers := Speakers}} -> hd([maps:without([error],X) || #{ssrc := I}=X <- Speakers,I=:=Ssrc]++[#{}]);
        _ -> #{}
    catch exit:_ -> #{} end;
engine_stats(_) -> #{}.
