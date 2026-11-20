%% ON AIR capture: one local source (system audio or microphone) captured by the
%% Device's native audio engine and published as one stream. Erlang decides the
%% stream (SSRC, SRTP key) and its receivers; the engine captures, encodes and
%% sends. No audio crosses here. One process per kind; kinds run concurrently,
%% each as its own stream (receivers mix them). The platform lists its kinds in
%% ba_app_session:configure/1 (audio_capture_sources).
-module(ba_audio_capture).
-behaviour(gen_server).
-export([start/1,stop/1,status/1,start_link/1,unavailable/0]).
-export([init/1,handle_call/3,handle_cast/2,handle_info/2,terminate/2,format_status/1]).

-define(RATE,48000).

start(Kind) ->
    case supported(Kind) of
        false -> {error,reason(Kind)};
        true ->
            ok=ba_audio_sup:ensure_started(),
            case supervisor:start_child(ba_session_scope:ref(ba_audio_sup),
                    #{id => name(Kind),start => {?MODULE,start_link,[Kind]},restart => temporary}) of
                {ok,P} -> gen_server:call(P,start);
                {error,{already_started,P}} -> gen_server:call(P,start);
                E -> E
            end
    end.
stop(Kind) -> case ba_session_scope:whereis(name(Kind)) of undefined -> ok;P -> gen_server:call(P,stop) end.
status(Kind) ->
    case {supported(Kind),ba_session_scope:whereis(name(Kind))} of
        {false,_} -> #{state => unsupported,error => reason(Kind)};
        {true,undefined} -> #{state => stopped};
        {true,P} -> gen_server:call(P,status)
    end.
%% What this platform cannot send, with the reason shown to the user.
unavailable() -> maps:from_list([{atom_to_binary(K),reason(K)} || K <- [microphone,broadcast],not supported(K)]).

supported(Kind) -> lists:member(Kind,ba_settings:app(audio_capture_sources,[])).
reason(microphone) -> <<"This Device cannot send its microphone.">>;
reason(broadcast) -> <<"This Device cannot share its system audio (iOS allows no app to record other apps).">>.
name(broadcast) -> ba_audio_capture_broadcast;
name(microphone) -> ba_audio_capture_microphone.
source(broadcast) -> {<<"system">>,<<"default-output">>,<<"System audio — FLAC"/utf8>>};
source(microphone) -> {<<"mic">>,<<"microphone">>,<<"Microphone — FLAC"/utf8>>}.

start_link(Kind) -> gen_server:start_link(ba_session_scope:registration(name(Kind)),?MODULE,Kind,[]).
init(Kind) -> process_flag(trap_exit,true),{ok,#{kind => Kind,state => stopped,peers => #{}}}.

handle_call(start,{Caller,_},#{kind := Kind,state := stopped}=S) ->
    case ba_device_permission:enter(Kind) of
        {ok,Token} ->
            Owners=lists:usort([Caller]++[P || Name <- [ba_device_config,ba_permission_pg],P <- [whereis(Name)],is_pid(P)]++
                [P || Name <- [ba_session,ba_device_handler,ba_device_sup,ba_device_worker_sup],P <- [ba_session_scope:whereis(Name)],is_pid(P)]),
            [monitor(process,P) || P <- Owners],
            {ok,Engine}=ba_audio_engine:ensure(),
            monitor(process,Engine),
            Ssrc=rand:uniform(16#ffffffff),Key=crypto:strong_rand_bytes(30),
            {Engine_source,_,_}=source(Kind),
            %% The first start may wait for the OS permission prompt: never
            %% block the caller; publish once the engine confirms.
            Request=ba_audio_engine:send_command(Engine,#{op => start_capture,source => Engine_source,ssrc => Ssrc,
                rate => ?RATE,key => Key,peers => []}),
            erlang:send_after(250,self(),heartbeat),
            {reply,ok,S#{state := starting,request => Request,token => Token,owners => Owners,engine => Engine,
                ssrc => Ssrc,key => Key}};
        E -> {reply,E,S}
    end;
handle_call(start,_,S) -> {reply,ok,S};
handle_call(status,_,S) -> {reply,maps:with([state,error],S),S};
handle_call({stream,kind},_,#{kind := Kind}=S) -> {reply,{ok,Kind},S};
handle_call({stream,describe},_,#{anchor := Anchor}=S) ->
    {reply,{ok,#{ssrc => maps:get(ssrc,S),key => maps:get(key,S),anchor_ns => Anchor,rate => ?RATE}},S};
handle_call({stream,describe},_,S) -> {reply,{error,capture_starting},S};
handle_call({stream,{add_peers,Media,Peers}},_,#{peers := Known}=S) ->
    case maps:is_key(Media,Known) of true -> ok;false -> monitor(process,Media) end,
    Next=S#{peers := Known#{Media => Peers}},
    {reply,route(Next),Next};
handle_call(stop,_,S) -> {reply,ok,stop_capture(S)};
handle_call({revoke_permissions,_},_,S) -> {reply,ok,stop_capture(S)};
handle_call(_,_,S) -> {reply,{error,capture_not_running},S}.
handle_cast(_,S) -> {noreply,S}.

handle_info(Message,#{request := Request,kind := Kind}=S) ->
    case gen_server:check_response(Message,Request) of
        no_reply -> info(Message,S);
        {reply,{ok,_}} ->
            D=#{encoding => pcm,sample_format => float32_le,sample_rate => ?RATE,channel_count => 2,
                clock => ba_session_clock:id(),stream_handler => engine_flac},
            {_,Key,Name}=source(Kind),
            {ok,Source}=ba_audio:publish(#{source_key => Key,name => Name,profiles => #{channel => D}},self()),
            monitor(process,Source),
            {noreply,(maps:remove(request,S))#{state := running,source => Source,source_clock => maps:get(clock,D)}};
        {reply,{error,Text}} -> {noreply,(clear(maps:remove(request,S)))#{state := error,error => Text}};
        {error,{Reason,_}} -> {stop,{audio_engine,Reason},maps:remove(request,S)}
    end;
handle_info(Message,S) -> info(Message,S).

info({ba_audio_engine,Engine,#{event := <<"capture_started">>,anchor_ns := Anchor}},#{engine := Engine}=S) ->
    {noreply,S#{anchor => Anchor}};
info(heartbeat,#{kind := Kind,state := State,token := Token}=S) when State=:=running;State=:=starting ->
    case ba_device_permission:valid(Kind,Token) of
        false -> {stop,consent_revoked,stop_capture(S)};
        true ->
            erlang:send_after(250,self(),heartbeat),
            Clock=ba_session_clock:id(),
            case Clock=:=maps:get(source_clock,S,Clock) of
                true -> {noreply,S};
                false -> ok=ba_audio:rebind(maps:get(source,S),Clock),{noreply,S#{source_clock := Clock}}
            end
    end;
info({'DOWN',_,process,Pid,_},#{peers := Peers}=S) when is_map_key(Pid,Peers) ->
    Next=S#{peers := maps:remove(Pid,Peers)},route(Next),{noreply,Next};
info({'DOWN',_,process,Engine,_},#{engine := Engine}=S) ->
    unpublish(S),{noreply,(clear(S))#{state := error,error => <<"The audio engine stopped; see chat for its report.">>}};
info({'DOWN',_,process,_,_},S) -> {stop,owner_down,stop_capture(S)};
info(_,S) -> {noreply,S}.

terminate(_,S) -> stop_capture(S),ok.
format_status(Status) -> maps:map(fun(state,S) -> maps:with([kind,state,ssrc],S);(log,_) -> [];(_,_) -> redacted end,Status).

%% Every receiver's routed address; the engine sends each packet to all of them.
route(#{engine := Engine,ssrc := Ssrc,peers := Peers}) ->
    {ok,_}=ba_audio_engine:command(Engine,#{op => route,ssrc => Ssrc,peers => lists:append(maps:values(Peers))}),ok.

stop_capture(#{state := State,engine := Engine}=S) when State=:=running;State=:=starting ->
    try ba_audio_engine:command(Engine,#{op => stop_capture,ssrc => maps:get(ssrc,S)},2000) catch exit:_ -> ok end,
    unpublish(S),(clear(S))#{state := stopped};
stop_capture(S) -> S.
unpublish(#{source := Source}) -> try ba_audio:unpublish(Source) catch exit:_ -> ok end;
unpublish(_) -> ok.
clear(S) -> (maps:without([engine,ssrc,key,anchor,source,source_clock,token],S))#{peers := #{}}.
