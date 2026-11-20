%% Owner of one native audio engine (an OTP port program). Erlang decides; the
%% engine executes: commands are maps sent with term_to_binary/1 over
%% {packet,4}, replies and events come back as terms. No audio crosses this
%% port. If the engine dies, this process stops with its crash report, which is
%% logged and posted in full to Session chat (development choice, owner
%% 2026-11-20). See docs/AUDIO_ENGINE.md.
-module(ba_audio_engine).
-behaviour(gen_server).
-export([start_link/0,start_link/1,ensure/0,command/2,command/3,send_command/2,udp_port/1,mapped/1,listen/2,available/0,executable/0]).
-export([init/1,handle_call/3,handle_cast/2,handle_info/2,terminate/2]).

-define(CLOCK_INTERVAL,5000).
-define(STUN_INTERVAL,60000).
-define(MAX_PPM,500).
%% A probe slower than this was delayed by a busy VM (on iPhone the VM shares the
%% app's CPU with the UI): its midpoint is not the engine's time; skip it.
-define(MAX_PROBE_NS,5000000).
-define(CHAT_LIMIT,4000).

%% One engine per Device, in its Session runtime: it owns one UDP socket and
%% serves every speaker and the capture. ensure/0 starts it on first use; it is
%% not restarted automatically, so a crash stays visible until audio is needed again.
start_link() -> gen_server:start_link(ba_session_scope:registration(?MODULE),?MODULE,#{owner => undefined},[]).
ensure() ->
    ok=ba_audio_sup:ensure_started(),
    case supervisor:start_child(ba_session_scope:ref(ba_audio_sup),
            #{id => ?MODULE,start => {?MODULE,start_link,[]},restart => temporary}) of
        {ok,Pid} -> {ok,Pid};
        {error,{already_started,Pid}} -> {ok,Pid};
        {error,already_present} ->
            _=supervisor:delete_child(ba_session_scope:ref(ba_audio_sup),?MODULE),ensure();
        Error -> Error
    end.
available() -> ba_settings:env("BA_AUDIO_ENGINE_PORT")=/=false orelse filelib:is_regular(executable()).

%% A standalone engine (tests, measurements). Options: owner (receives
%% {ba_audio_engine,Pid,Event} for events no stream claims), executable
%% (defaults to executable/0), clock (fun from Erlang monotonic ns to Session ns
%% or unavailable; defaults to the Session clock), udp_port (default 0: any).
start_link(Opts) -> gen_server:start_link(?MODULE,Opts#{owner => maps:get(owner,Opts,self())},[]).
udp_port(Pid) -> gen_server:call(Pid,udp_port).
%% The engine socket's public address as STUN last saw it: [] or [[Host,Port]].
mapped(Pid) -> gen_server:call(Pid,mapped).
%% Engine events carrying this probe token go to the caller.
listen(Pid,Token) -> gen_server:call(Pid,{listen,Token}).
%% Returns {ok,Reply} or {error,Text}; Reply is the engine's map without id/op/event.
command(Pid,Command) -> command(Pid,Command,5000).
command(Pid,Command,Timeout) -> gen_server:call(Pid,{command,Command},Timeout).
%% For commands that may wait on the user (an OS permission prompt): the reply
%% arrives later; match it with gen_server:check_response/2.
send_command(Pid,Command) -> gen_server:send_request(Pid,{command,Command}).

executable() ->
    case ba_settings:env("BA_AUDIO_ENGINE") of
        %% Source-tree runtimes (CLI, Web UI): ba_core is built at
        %% builds/intermediates/control/default/lib/ba_core; apps set the variable.
        false -> filename:absname(filename:join([code:lib_dir(ba_core),"..","..","..","..","..","CLI","ba_audio_engine"]));
        Path -> Path
    end.

init(Opts) ->
    process_flag(trap_exit,true),
    {Kind,Port,Crash}=connect(Opts),
    S=#{port => Port,kind => Kind,owner => maps:get(owner,Opts),crash_file => Crash,next => 1,calls => #{},revision => 0,
        clock => maps:get(clock,Opts,fun session_time/1)},
    %% An in-process engine (iOS) takes the app down when it crashes; its report
    %% waits in the crash file for the next launch.
    case filelib:is_regular(Crash) of
        true -> report(iolist_to_binary(["Audio engine crashed in the previous run.\n",crash_text(Crash)]));
        false -> ok
    end,
    {ok,#{version := 1}}=sync(#{op => hello},S),
    {ok,#{port := Udp}}=sync(#{op => open,port => maps:get(udp_port,Opts,0)},S),
    S1=map_clock(first,S#{udp_port => Udp,listeners => #{},mapped => [],stun => undefined}),
    erlang:send_after(?CLOCK_INTERVAL,self(),clock),
    self() ! stun,
    {ok,S1}.

handle_call(udp_port,_,S) -> {reply,maps:get(udp_port,S),S};
handle_call(mapped,_,S) -> {reply,maps:get(mapped,S),S};
handle_call({listen,Token},{Caller,_},S) -> {reply,ok,S#{listeners := (maps:get(listeners,S))#{Token => Caller}}};
handle_call({command,C},{Caller,_}=From,#{next := Id}=S) ->
    send(C#{id => Id},S),
    %% Events about a stream (e.g. capture_started) go to whoever started it.
    Listeners=case C of
        #{op := Op,ssrc := Ssrc} when Op=:=start_capture;Op=:=start_speaker -> (maps:get(listeners,S))#{Ssrc => Caller};
        #{op := probe,token := Token} -> (maps:get(listeners,S))#{Token => Caller};
        _ -> maps:get(listeners,S)
    end,
    {noreply,S#{next := Id+1,calls := (maps:get(calls,S))#{Id => {caller,From}},listeners := Listeners}}.
handle_cast(_,S) -> {noreply,S}.

handle_info({Port,{data,B}},#{port := Port}=S) -> {noreply,event(binary_to_term(B),S)};
handle_info({tcp,Port,B},#{port := Port}=S) -> {noreply,event(binary_to_term(B),S)};
handle_info({tcp_closed,Port},#{port := Port}=S) -> {stop,native_engine_closed,maps:remove(port,S)};
%% Periodic probes are ordinary asynchronous commands: the engine may be busy
%% (an OS permission prompt can hold a command for minutes) and this process
%% must keep serving meanwhile.
handle_info(clock,S) ->
    erlang:send_after(?CLOCK_INTERVAL,self(),clock),
    {noreply,async(#{op => clock},{clock_probe,erlang:monotonic_time(nanosecond)},S)};
%% NAT traversal: refresh the public address now and then; DNS runs apart so
%% this process never waits on it.
handle_info(stun,S) ->
    erlang:send_after(?STUN_INTERVAL,self(),stun),
    Owner=self(),
    spawn(fun() -> Owner ! {stun_servers,stun_servers()} end),
    {noreply,S};
handle_info({stun_servers,[]},S) -> {noreply,S};
handle_info({stun_servers,Servers},S) ->
    Token=crypto:strong_rand_bytes(12),
    {noreply,async(#{op => stun,token => Token,servers => Servers},stun_sent,S#{stun := Token})};
handle_info({Port,{exit_status,Status}},#{port := Port,crash_file := Crash}=S) ->
    report(iolist_to_binary([io_lib:format("Audio engine exited with status ~p.~n",[Status]),crash_text(Crash)])),
    {stop,{native_engine_exit,Status},maps:remove(port,S)};
handle_info({'EXIT',Port,Reason},#{port := Port}=S) -> {stop,{native_engine_port,Reason},maps:remove(port,S)};
handle_info(_,S) -> {noreply,S}.

terminate(_,#{kind := program,port := Port}) -> try port_close(Port) catch error:badarg -> ok end,ok;
terminate(_,#{kind := loopback,port := Socket}) -> gen_tcp:close(Socket);
terminate(_,_) -> ok.

%% ---- Control connection ------------------------------------------------------
%% A port program where the OS allows one; the in-process engine's loopback
%% socket on iOS (BA_AUDIO_ENGINE_PORT). Same {packet,4} term frames either way.
connect(Opts) ->
    case ba_settings:env("BA_AUDIO_ENGINE_PORT") of
        false ->
            Crash=filename:join(filename:basedir(user_cache,"beam-audio"),
                "engine-crash-"++os:getpid()++"-"++integer_to_list(erlang:unique_integer([positive]))++".txt"),
            ok=filelib:ensure_dir(Crash),
            Exe=maps:get(executable,Opts,executable()),
            {program,open_port({spawn_executable,Exe},[{packet,4},binary,exit_status,use_stdio,{args,["--crash-file",Crash]}]),Crash};
        Text ->
            {ok,Socket}=gen_tcp:connect({127,0,0,1},list_to_integer(Text),[binary,{packet,4},{active,true},{nodelay,true}],2000),
            {loopback,Socket,ba_settings:env("BA_AUDIO_ENGINE_CRASH_FILE")}
    end.
%% A TCP socket is also an Erlang port: the kind, not is_port/1, tells them apart.
send(C,#{kind := program,port := Port}) -> true=port_command(Port,term_to_binary(C)),ok;
send(C,#{kind := loopback,port := Socket}) -> ok=gen_tcp:send(Socket,term_to_binary(C)).

event(#{event := <<"stun_reply">>,token := Token,host := Host,port := Port},#{stun := Token}=S) ->
    S#{mapped := [[Host,Port]]};
event(#{id := Id}=E,#{calls := Calls}=S) ->
    {Pending,Rest}=maps:take(Id,Calls),
    replied(Pending,reply(E),S#{calls := Rest});
event(E,S) ->
    Target=case E of
        #{ssrc := Ssrc} -> maps:get(Ssrc,maps:get(listeners,S),maps:get(owner,S));
        #{token := Token} -> maps:get(Token,maps:get(listeners,S),maps:get(owner,S));
        _ -> maps:get(owner,S)
    end,
    case is_pid(Target) of true -> Target ! {ba_audio_engine,self(),E};false -> ok end,
    S.

replied({caller,From},Reply,S) -> gen_server:reply(From,Reply),S;
replied({clock_probe,Sent},{ok,#{internal_ns := Internal,session_ns := Native}},S) ->
    Received=erlang:monotonic_time(nanosecond),
    case Received-Sent=<?MAX_PROBE_NS andalso (maps:get(clock,S))((Sent+Received) div 2) of
        Global when is_integer(Global) -> async(clock_map(Internal,Global,Native,S),clock_mapped,S#{revision := maps:get(revision,S)+1});
        _ -> S
    end;
replied(clock_mapped,{ok,_},S) -> S;
replied(stun_sent,{ok,_},S) -> S.
%% Configured STUN servers ("stun:host:port"), resolved to IPv4 addresses.
stun_servers() ->
    lists:append([try
        ["stun",Host|Rest]=string:split(binary_to_list(Url),":",all),
        Port=case Rest of [P] -> list_to_integer(P);[] -> 3478 end,
        {ok,Ip}=inet:getaddr(Host,inet),
        [[list_to_binary(inet:ntoa(Ip)),Port]]
    catch _:_ -> [] end || Url <- ba_settings:app(direct_stun_urls,[])]).
async(C,Pending,#{next := Id}=S) ->
    send(C#{id => Id},S),
    S#{next := Id+1,calls := (maps:get(calls,S))#{Id => Pending}}.

reply(#{event := <<"ok">>}=E) -> {ok,maps:without([id,op,event],E)};
reply(#{event := <<"error">>,error := Text}) -> {error,Text}.

%% Synchronous exchange before the gen_server loop runs (init, clock mapping).
%% Unsolicited events arriving meanwhile still reach the owner.
sync(C,#{port := Port,owner := Owner}=S) ->
    Id=make_ref_id(),
    send(C#{id => Id},S),
    sync_wait(Id,Port,Owner).
sync_wait(Id,Port,Owner) ->
    receive
        {Port,{data,B}} -> sync_frame(binary_to_term(B),Id,Port,Owner);
        {tcp,Port,B} -> sync_frame(binary_to_term(B),Id,Port,Owner);
        {Port,{exit_status,_}}=Exit -> self() ! Exit,{error,engine_exited};
        {tcp_closed,Port}=Closed -> self() ! Closed,{error,engine_exited};
        {'EXIT',Port,Reason} -> exit({native_engine_connection,Reason})
    after 5000 -> exit(native_engine_timeout)
    end.
sync_frame(#{id := Id}=E,Id,_,_) -> reply(E);
sync_frame(E,Id,Port,Owner) -> [Owner ! {ba_audio_engine,self(),E} || is_pid(Owner)],sync_wait(Id,Port,Owner).
make_ref_id() -> -erlang:unique_integer([positive]).

%% ---- Clock mapping --------------------------------------------------------------
%% The engine maps its host clock to Session time. The first mapping uses the
%% fastest of five probes; later ones correct the rate towards Session time
%% over about five seconds, never stepping it.
map_clock(first,S) ->
    case lists:sort([P || {ok,_,_,_}=P <- [probe(S) || _ <- lists:seq(1,5)]]) of
        [] -> S;
        [{ok,_Rtt,Internal,{Global,Native}}|_] ->
            Next=S#{revision := maps:get(revision,S)+1},
            {ok,_}=sync(clock_map(Internal,Global,Native,Next),Next),
            Next
    end.
clock_map(Internal,Global,Native,S) ->
    PPM=case Native of
        undefined -> 0.0;
        _ -> float(max(-?MAX_PPM,min(?MAX_PPM,(Global-Native)/5000)))
    end,
    #{op => clock_map,internal_ns => Internal,session_ns => Global,correction_ppm => PPM,revision => maps:get(revision,S)}.
probe(S) ->
    Sent=erlang:monotonic_time(nanosecond),
    {ok,#{internal_ns := Internal,session_ns := Native}}=sync(#{op => clock},S),
    Received=erlang:monotonic_time(nanosecond),
    case (maps:get(clock,S))((Sent+Received) div 2) of
        Global when is_integer(Global) -> {ok,Received-Sent,Internal,{Global,Native}};
        unavailable -> unavailable
    end.
session_time(Monotonic) ->
    case ba_session_clock:presentation([Monotonic]) of
        {ok,#{times := [Global]}} -> Global;
        _ -> unavailable
    end.

%% ---- Crash reports ----------------------------------------------------------------
crash_text(File) ->
    case file:read_file(File) of
        {ok,Text} -> _=file:delete(File),Text;
        _ -> <<"No crash report was written (the engine exited without a fatal signal or exception).\n">>
    end.
report(Report) -> logger:error("~ts",[Report]),post_chat(Report).

%% Session chat limits one entry to 4096 bytes; long reports go in parts.
post_chat(Report) ->
    case ba_session_scope:whereis(ba_session_chat) of
        undefined -> ok;
        _ -> [try ba_session_chat:send(Part) catch exit:_ -> ok end || Part <- chunks(Report)],ok
    end.
chunks(Text) when byte_size(Text)=<?CHAT_LIMIT -> [Text];
chunks(Text) ->
    Cut=case binary:matches(binary:part(Text,0,?CHAT_LIMIT),<<"\n">>) of
        [] -> ?CHAT_LIMIT;
        Matches -> element(1,lists:last(Matches))+1
    end,
    <<Part:Cut/binary,Rest/binary>> = Text,
    [Part|chunks(Rest)].
