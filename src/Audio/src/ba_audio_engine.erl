%% Owner of one native audio engine (an OTP port program). Erlang decides; the
%% engine executes: commands are maps sent with term_to_binary/1 over
%% {packet,4}, replies and events come back as terms. No audio crosses this
%% port. If the engine dies, this process stops with its crash report, which is
%% logged and posted in full to Session chat (development choice, owner
%% 2026-11-20). See docs/AUDIO_ENGINE.md.
-module(ba_audio_engine).
-behaviour(gen_server).
-export([start_link/0,start_link/1,ensure/0,command/2,command/3,send_command/2,udp_port/1,available/0,executable/0]).
-export([init/1,handle_call/3,handle_cast/2,handle_info/2,terminate/2]).

-define(CLOCK_INTERVAL,5000).
-define(MAX_PPM,500).
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
available() -> filelib:is_regular(executable()).

%% A standalone engine (tests, measurements). Options: owner (receives
%% {ba_audio_engine,Pid,Event} for events no stream claims), executable
%% (defaults to executable/0), clock (fun from Erlang monotonic ns to Session ns
%% or unavailable; defaults to the Session clock), udp_port (default 0: any).
start_link(Opts) -> gen_server:start_link(?MODULE,Opts#{owner => maps:get(owner,Opts,self())},[]).
udp_port(Pid) -> gen_server:call(Pid,udp_port).
%% Returns {ok,Reply} or {error,Text}; Reply is the engine's map without id/op/event.
command(Pid,Command) -> command(Pid,Command,5000).
command(Pid,Command,Timeout) -> gen_server:call(Pid,{command,Command},Timeout).
%% For commands that may wait on the user (an OS permission prompt): the reply
%% arrives later; match it with gen_server:check_response/2.
send_command(Pid,Command) -> gen_server:send_request(Pid,{command,Command}).

executable() ->
    case ba_settings:env("BA_AUDIO_ENGINE") of
        false -> filename:join([code:lib_dir(ba_core),"..","..","..","..","CLI","ba_audio_engine"]);
        Path -> Path
    end.

init(Opts) ->
    process_flag(trap_exit,true),
    Crash=filename:join(filename:basedir(user_cache,"beam-audio"),
        "engine-crash-"++os:getpid()++"-"++integer_to_list(erlang:unique_integer([positive]))++".txt"),
    ok=filelib:ensure_dir(Crash),
    Exe=maps:get(executable,Opts,executable()),
    Port=open_port({spawn_executable,Exe},[{packet,4},binary,exit_status,use_stdio,{args,["--crash-file",Crash]}]),
    S=#{port => Port,owner => maps:get(owner,Opts),crash_file => Crash,next => 1,calls => #{},revision => 0,
        clock => maps:get(clock,Opts,fun session_time/1)},
    {ok,#{version := 1}}=sync(#{op => hello},S),
    {ok,#{port := Udp}}=sync(#{op => open,port => maps:get(udp_port,Opts,0)},S),
    S1=map_clock(first,S#{udp_port => Udp,listeners => #{}}),
    erlang:send_after(?CLOCK_INTERVAL,self(),clock),
    {ok,S1}.

handle_call(udp_port,_,S) -> {reply,maps:get(udp_port,S),S};
handle_call({command,C},{Caller,_}=From,#{next := Id}=S) ->
    send(C#{id => Id},S),
    %% Events about a stream (e.g. capture_started) go to whoever started it.
    Listeners=case C of
        #{op := Op,ssrc := Ssrc} when Op=:=start_capture;Op=:=start_speaker -> (maps:get(listeners,S))#{Ssrc => Caller};
        _ -> maps:get(listeners,S)
    end,
    {noreply,S#{next := Id+1,calls := (maps:get(calls,S))#{Id => {caller,From}},listeners := Listeners}}.
handle_cast(_,S) -> {noreply,S}.

handle_info({Port,{data,B}},#{port := Port}=S) -> {noreply,event(binary_to_term(B),S)};
%% Periodic probes are ordinary asynchronous commands: the engine may be busy
%% (an OS permission prompt can hold a command for minutes) and this process
%% must keep serving meanwhile.
handle_info(clock,S) ->
    erlang:send_after(?CLOCK_INTERVAL,self(),clock),
    {noreply,async(#{op => clock},{clock_probe,erlang:monotonic_time(nanosecond)},S)};
handle_info({Port,{exit_status,Status}},#{port := Port}=S) ->
    Report=crash_report(Status,S),
    logger:error("~ts",[Report]),
    post_chat(Report),
    {stop,{native_engine_exit,Status},maps:remove(port,S)};
handle_info({'EXIT',Port,Reason},#{port := Port}=S) -> {stop,{native_engine_port,Reason},maps:remove(port,S)};
handle_info(_,S) -> {noreply,S}.

terminate(_,#{port := Port}) -> try port_close(Port) catch error:badarg -> ok end,ok;
terminate(_,_) -> ok.

%% ---- Port protocol ------------------------------------------------------------
send(C,#{port := Port}) -> true=port_command(Port,term_to_binary(C)),ok.

event(#{id := Id}=E,#{calls := Calls}=S) ->
    {Pending,Rest}=maps:take(Id,Calls),
    replied(Pending,reply(E),S#{calls := Rest});
event(E,S) ->
    Target=case E of
        #{ssrc := Ssrc} -> maps:get(Ssrc,maps:get(listeners,S),maps:get(owner,S));
        _ -> maps:get(owner,S)
    end,
    case is_pid(Target) of true -> Target ! {ba_audio_engine,self(),E};false -> ok end,
    S.

replied({caller,From},Reply,S) -> gen_server:reply(From,Reply),S;
replied({clock_probe,Sent},{ok,#{internal_ns := Internal,session_ns := Native}},S) ->
    case (maps:get(clock,S))((Sent+erlang:monotonic_time(nanosecond)) div 2) of
        Global when is_integer(Global) -> async(clock_map(Internal,Global,Native,S),clock_mapped,S#{revision := maps:get(revision,S)+1});
        unavailable -> S
    end;
replied(clock_mapped,{ok,_},S) -> S.
async(C,Pending,#{next := Id}=S) ->
    send(C#{id => Id},S),
    S#{next := Id+1,calls := (maps:get(calls,S))#{Id => Pending}}.

reply(#{event := <<"ok">>}=E) -> {ok,maps:without([id,op,event],E)};
reply(#{event := <<"error">>,error := Text}) -> {error,Text}.

%% Synchronous exchange before the gen_server loop runs (init, clock mapping).
%% Unsolicited events arriving meanwhile still reach the owner.
sync(C,#{port := Port,owner := Owner}) ->
    Id=make_ref_id(),
    send(C#{id => Id},#{port => Port}),
    sync_wait(Id,Port,Owner).
sync_wait(Id,Port,Owner) ->
    receive
        {Port,{data,B}} ->
            case binary_to_term(B) of
                #{id := Id}=E -> reply(E);
                E -> [Owner ! {ba_audio_engine,self(),E} || is_pid(Owner)],sync_wait(Id,Port,Owner)
            end;
        {Port,{exit_status,_}}=Exit -> self() ! Exit,{error,engine_exited}
    after 5000 -> exit(native_engine_timeout)
    end.
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
crash_report(Status,#{crash_file := File}) ->
    Body=case file:read_file(File) of
        {ok,Text} -> _=file:delete(File),Text;
        _ -> <<"No crash report was written (the engine exited without a fatal signal or exception).\n">>
    end,
    iolist_to_binary([io_lib:format("Audio engine exited with status ~p.~n",[Status]),Body]).

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
