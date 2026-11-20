%% Mac ON AIR: system audio captured by the Device's native audio engine and
%% published as one stream. Erlang decides the stream (SSRC, SRTP key) and its
%% receivers; the engine captures, encodes and sends. No audio crosses here.
-module(ba_mac_native_audio).
-behaviour(gen_server).
-export([start/1,stop/1,status/1,start_link/0,unavailable/0]).
-export([init/1,handle_call/3,handle_cast/2,handle_info/2,terminate/2,format_status/1]).

-define(RATE,48000).

%% Native microphone capture does not exist yet (owner accepted the gap).
start(microphone) -> {error,native_microphone_unavailable};
start(broadcast) ->
    ok=ba_audio_sup:ensure_started(),
    case supervisor:start_child(ba_session_scope:ref(ba_audio_sup),#{id => ?MODULE,start => {?MODULE,start_link,[]},restart => temporary}) of
        {ok,P} -> gen_server:call(P,start);{error,{already_started,P}} -> gen_server:call(P,start);E -> E end.
stop(microphone) -> ok;
stop(broadcast) -> case ba_session_scope:whereis(?MODULE) of undefined -> ok;P -> gen_server:call(P,stop) end.
status(microphone) -> #{state => unsupported,error => <<"Native microphone capture is not available yet.">>};
status(broadcast) -> case ba_session_scope:whereis(?MODULE) of undefined -> #{state => stopped};P -> gen_server:call(P,status) end.
unavailable() -> #{<<"microphone">> => <<"Native microphone capture is not available yet.">>}.

start_link() -> gen_server:start_link(ba_session_scope:registration(?MODULE),?MODULE,[],[]).
init([]) -> process_flag(trap_exit,true),{ok,#{state => stopped,peers => #{}}}.

handle_call(start,{Caller,_},#{state := stopped}=S) ->
    case ba_device_permission:enter(broadcast) of
        {ok,Token} ->
            Owners=lists:usort([Caller]++[P || Name <- [ba_device_config,ba_permission_pg],P <- [whereis(Name)],is_pid(P)]++
                [P || Name <- [ba_session,ba_device_handler,ba_device_sup,ba_device_worker_sup],P <- [ba_session_scope:whereis(Name)],is_pid(P)]),
            [monitor(process,P) || P <- Owners],
            {ok,Engine}=ba_audio_engine:ensure(),
            monitor(process,Engine),
            Ssrc=rand:uniform(16#ffffffff),Key=crypto:strong_rand_bytes(30),
            %% The first start may wait for macOS's System Audio Recording
            %% prompt: never block the caller; publish once the engine confirms.
            Request=ba_audio_engine:send_command(Engine,#{op => start_capture,source => <<"system">>,ssrc => Ssrc,
                rate => ?RATE,key => Key,peers => []}),
            erlang:send_after(250,self(),heartbeat),
            {reply,ok,S#{state := starting,request => Request,token => Token,owners => Owners,engine => Engine,
                ssrc => Ssrc,key => Key}};
        E -> {reply,E,S}
    end;
handle_call(start,_,S) -> {reply,ok,S};
handle_call(status,_,S) -> {reply,maps:with([state,error],S),S};
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

handle_info(Message,#{request := Request}=S) ->
    case gen_server:check_response(Message,Request) of
        no_reply -> info(Message,S);
        {reply,{ok,_}} ->
            D=#{encoding => pcm,sample_format => float32_le,sample_rate => ?RATE,channel_count => 2,
                clock => ba_session_clock:id(),stream_handler => engine_flac},
            {ok,Source}=ba_audio:publish(#{source_key => <<"default-output">>,
                name => <<"Mac output — FLAC (native engine)"/utf8>>,profiles => #{channel => D}},self()),
            monitor(process,Source),
            {noreply,(maps:remove(request,S))#{state := running,source => Source,source_clock => maps:get(clock,D)}};
        {reply,{error,Text}} -> {noreply,(clear(maps:remove(request,S)))#{state := error,error => Text}};
        {error,{Reason,_}} -> {stop,{audio_engine,Reason},maps:remove(request,S)}
    end;
handle_info(Message,S) -> info(Message,S).

info({ba_audio_engine,Engine,#{event := <<"capture_started">>,anchor_ns := Anchor}},#{engine := Engine}=S) ->
    {noreply,S#{anchor => Anchor}};
info(heartbeat,#{state := State,token := Token}=S) when State=:=running;State=:=starting ->
    case ba_device_permission:valid(broadcast,Token) of
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
format_status(Status) -> maps:map(fun(state,S) -> maps:with([state,ssrc],S);(log,_) -> [];(_,_) -> redacted end,Status).

%% Every receiver's addresses; the engine sends each packet to all of them.
route(#{engine := Engine,ssrc := Ssrc,peers := Peers}) ->
    {ok,_}=ba_audio_engine:command(Engine,#{op => route,ssrc => Ssrc,peers => lists:append(maps:values(Peers))}),ok.

stop_capture(#{state := State,engine := Engine}=S) when State=:=running;State=:=starting ->
    try ba_audio_engine:command(Engine,#{op => stop_capture},2000) catch exit:_ -> ok end,
    unpublish(S),(clear(S))#{state := stopped};
stop_capture(S) -> S.
unpublish(#{source := Source}) -> try ba_audio:unpublish(Source) catch exit:_ -> ok end;
unpublish(_) -> ok.
clear(S) -> (maps:without([engine,ssrc,key,anchor,source,source_clock,token],S))#{peers := #{}}.
