%% Console projection of ordinary Session-member observations. No PCM or audio I/O.
-module(ba_cli_monitor).
-export([run/2,run_local/1,render/1,render/2]).
%% Embedded launchers use the same monitor loop without a second Device/socket.
run_local(Options) ->
    Request=fun(Command) ->
        json:decode(iolist_to_binary(json:encode(ba_device_api:request(Command))))
    end,
    loop(Request,Options,false,#{},#{},#{}).
monitor_request(Request,Command) when is_function(Request,1) -> Request(Command);
monitor_request(Name,Command) -> ba_cli:request(Name,Command).
run(A,Root) ->
    case maps:get(all,A,false) of true -> ok;false -> fail(<<"Use beamaudio monitor --all.">>) end,
    _=ba_cli:timeout(A),
    Name=case maps:find(devicename,A) of
        {ok,Selected} ->
            _=ba_cli:request(Selected,#{<<"method">> => <<"snapshot">>}),
            remember_local(Selected,A),
            io:format(standard_error,"Monitoring local Device ~s and its current Session. Ctrl-C exits this view.~n",[Selected]),
            Selected;
        error ->
            io:put_chars(standard_error,"Connecting Session monitor (audio stays disabled)...\n"),
            Observer=choose(A,Root),
            io:format(standard_error,"Monitoring through Device ~s. Audio disabled. Ctrl-C exits this view; Device stays connected.~n",[Observer]),
            Observer
    end,
    follow_chat(Name,filename:join([Root,"builds/live/chat.log"])),
    loop(Name,A,maps:get(metrics,A,false),#{},#{},#{}).
%% Live tests: every chat entry the monitored Device sees is appended to a file
%% Claude can read while the owner tests. One line per entry, never rewritten.
follow_chat(Name,Path) ->
    ok=filelib:ensure_dir(Path),
    io:format(standard_error,"Session chat is appended to ~ts~n",[Path]),
    spawn_link(fun() -> chat_loop(Name,Path,sets:new([{version,2}])) end).
chat_loop(Name,Path,Seen) ->
    Next=try ba_cli:request(Name,#{<<"method">> => <<"snapshot">>}) of
        R ->
            Names=maps:from_list([{maps:get(<<"id">>,D),maps:get(<<"name">>,D,<<>>)} || D <- maps:get(<<"devices">>,R,[])]),
            New=[M || M <- maps:get(<<"messages">>,R,[]),not sets:is_element(key(M),Seen)],
            case New of
                [] -> ok;
                _ -> ok=file:write_file(Path,[chat_line(M,Names) || M <- New],[append])
            end,
            lists:foldl(fun(M,Acc) -> sets:add_element(key(M),Acc) end,Seen,New)
    catch throw:{cli_error,_,_} -> Seen end,
    receive after 1000 -> chat_loop(Name,Path,Next) end.
key(M) -> {maps:get(<<"id">>,M),maps:get(<<"sender">>,M)}.
chat_line(M,Names) ->
    Time=calendar:system_time_to_rfc3339(maps:get(<<"time">>,M),[{unit,second},{offset,"Z"}]),
    Sender=maps:get(<<"sender">>,M),
    Who=case maps:get(Sender,Names,<<>>) of <<>> -> binary:part(Sender,0,min(12,byte_size(Sender)));N -> N end,
    [Time," ",Who,": ",maps:get(<<"text">>,M),"\n"].
choose(A,Root) ->
    Parsed=invitation(A,Root),
    case Parsed of
        {Invitation,Body} ->
            Id=maps:get(<<"session">>,Body),Name="ba-monitor-"++binary_to_list(Id),
            ensure(Name,Invitation,Id,A,Root),remember(Invitation,A),Name;
        invalid ->
            case maps:get(no_user_state,A,false) of
                true -> fail(<<"With --no-user-state, supply --invitation-file or --devicename.">>);
                false -> ok
            end,
            Candidates=case maps:find(devicename,A) of {ok,Selected} -> [Selected];error -> [Candidate || Candidate <- ba_cli_store:names(),lists:prefix("ba-monitor-",Candidate)] end,
            Live=[N || N <- Candidates,live_observer(N)],
            case Live of
                [N] -> io:put_chars(standard_error,"Using existing authorized observer; no new invitation is required.\n"),N;
                [] -> fail(<<"No active observer or valid saved invitation. Supply a fresh --invitation-file. No Session was created.">>);
                _ -> fail(<<"Several observers are active. Select one with --devicename or a valid --invitation-file.">>)
            end
    end.
invitation(A,Root) ->
    Saved=case maps:is_key(invitation_file,A) orelse maps:get(no_user_state,A,false) of
        true -> {error,not_selected};false -> ba_cli_store:last_session()
    end,
    Data=case Saved of
        {ok,_} -> Saved;
        _ -> case maps:get(no_user_state,A,false) andalso not maps:is_key(invitation_file,A) of
            true -> {error,not_selected};false -> file:read_file(invitation_path(A,Root))
        end
    end,
    case Data of
        {ok,B} -> Link=string:trim(B),try {_,I}=ba_session_passport:parse_invitation(Link),{Link,I} catch _:_ -> invalid end;
        _ -> invalid
    end.
remember(Link,A) ->
    case maps:get(no_user_state,A,false) of
        true -> ok;
        false -> case ba_cli_store:remember_session(Link) of
            ok -> ok;_ -> io:put_chars(standard_error,"Could not save the monitor's last Session.\n")
        end
    end.
remember_local(Name,A) ->
    case maps:get(no_user_state,A,false) of
        true -> ok;
        false -> try ba_cli:request(Name,#{<<"method">> => <<"invitation">>}) of
            #{<<"result">> := Link} when is_binary(Link) -> remember(Link,A);
            _ -> ok
        catch throw:{cli_error,_,_} -> ok end
    end.
live_observer(Name) ->
    try
        R=ba_cli:request(Name,#{<<"method">> => <<"snapshot">>}),
        maps:get(<<"observer">>,maps:get(<<"managed">>,R),false) andalso
        maps:get(<<"state">>,maps:get(<<"session">>,R))=:=<<"authorized">>
    catch _:_ -> false end.

invitation_path(A,Root) -> maps:get(invitation_file,A,filename:join([Root,"builds/CLI/private/monitor-invitation.txt"])).
ensure(Name,Link,Id,A,Root) ->
    case ba_cli_store:read(Name) of
        {error,not_running} ->
            ba_cli:new_device(#{devicename => Name,enable => "",createsession => false,joinsession => binary_to_list(Link),
                observer => true,until => "admitted",timeout => maps:get(timeout,A,"120s")},Root),ok;
        {ok,_} ->
            R=ba_cli:request(Name,#{<<"method">> => <<"snapshot">>}),
            case maps:get(<<"observer">>,maps:get(<<"managed">>,R),false) of true -> ok;false -> fail(<<"Reserved monitor name is owned by a non-observer Device.">>) end,
            Session=maps:get(<<"session">>,R),
            case {maps:get(<<"state">>,Session),maps:get(<<"session">>,Session,null)} of
                {<<"idle">>,_} -> ba_cli:request(Name,#{<<"method">> => <<"join_session">>,<<"invitation">> => Link});
                {<<"authorized">>,Id} -> ok;
                {_,Id} ->
                    ba_cli:request(Name,#{<<"method">> => <<"leave_session">>}),
                    ba_cli:request(Name,#{<<"method">> => <<"join_session">>,<<"invitation">> => Link});
                _ -> fail(<<"Monitor belongs to another live gathering. Stop it before changing invitations.">>)
            end,
            await_admission(Name,erlang:monotonic_time(millisecond)+ba_cli:timeout(A),undefined);
        _ -> fail(<<"Monitor process record is unavailable; inspect its private runtime.log.">>)
    end.
await_admission(Name,Until,LastState) ->
    Reply=ba_cli:request(Name,#{<<"method">> => <<"readiness">>}),
    View=maps:get(<<"result">>,Reply),State=maps:get(<<"membership_state">>,View),
    case maps:get(<<"admitted">>,View) of
        true -> ok;
        false ->
            case State of
                <<"idle">> -> fail(<<"The saved gathering is no longer active. Supply a valid invitation from the current Session (--invitation-file PATH).">>);
                <<"revoked">> -> fail(<<"Admission was denied. Check revocation and that the Owner is online.">>);
                <<"ended">> -> fail(<<"The saved Session ended. A new Session needs a valid invitation.">>);
                _ -> ok
            end,
            case State=:=LastState of
                true -> ok;
                false -> io:format(standard_error,"Waiting for admission (~ts); checking the saved invitation's gathering...~n",[safe(State)])
            end,
            case erlang:monotonic_time(millisecond)>=Until of
                true -> fail(<<"Timed out joining the saved Session. Keep its Owner online or supply a fresh invitation from the current Session.">>);
                false -> receive after 250 -> ok end,await_admission(Name,Until,State)
            end
    end.

loop(Name,A,Metrics,Plain,Instances,Names) ->
    Now=erlang:monotonic_time(millisecond),
    Skip=[Id || {Id,#{retry := Until}} <- maps:to_list(Plain),Now<Until],
    %% A watch outlives one failed read: show it and try again on the next tick.
    try monitor_request(Name,#{<<"method">> => <<"monitor">>,<<"metrics">> => Metrics,<<"plain">> => Skip}) of
        R -> show(R,Name,A,Metrics,Plain,Instances,Names,Now)
    catch throw:{cli_error,_,Detail} when not (is_map_key(once,A) andalso map_get(once,A) =:= true) ->
        io:put_chars(["Device read failed, retrying: ",safe(error_text(Detail)),"\n"]),
        receive stop_monitor -> ok after maps:get(interval,A,1000) -> loop(Name,A,Metrics,Plain,Instances,Names) end
    end.
error_text(#{error := E}) when is_binary(E) -> E;
error_text(#{error := E}) -> iolist_to_binary(io_lib:format("~p",[E]));
error_text(_) -> <<"unknown error">>.
show(R,Name,A,Metrics,Plain,Instances,Names,Now) ->
    Raw=maps:get(<<"result">>,R),
    Rows=[case maps:get(<<"name">>,Row,maps:get(maps:get(<<"id">>,Row),Names,<<>>)) of
        <<>> -> Row;N -> Row#{<<"name">> => N}
    end || Row <- maps:get(<<"devices">>,Raw)],
    Data=Raw#{<<"devices">> := Rows},
    NextNames=maps:from_list([{maps:get(<<"id">>,Row),N} || Row <- Rows,
        N <- [maps:get(<<"name">>,Row,<<>>)],N=/=<<>>]),
    case maps:get(json,A,false) of
        true -> io:put_chars([json:encode(Data),$\n]);
        false ->
            case io:columns() of {ok,_} -> io:put_chars(<<27,"[H",27,"[2J">>);_ -> ok end,
            io:put_chars(render(Data,terminal_color()))
    end,
    {NextPlain,NextInstances}=lists:foldl(fun(Row,{P,Is}) ->
        Id=maps:get(<<"id">>,Row),State=maps:get(<<"state">>,Row),Caps=maps:get(<<"capabilities">>,Row,#{}),
        case maps:find(<<"instance">>,Caps) of
            {ok,I} ->
                Changed=maps:get(Id,Is,I)=/=I,
                {case Changed of true -> maps:remove(Id,P);false -> P end,Is#{Id => I}};
            error when Metrics,State=:=<<"request_timeout">>;Metrics,State=:=<<"timeout">> ->
                {P#{Id => #{retry => Now+30000}},Is};
            error -> {P,Is}
        end
    end,{Plain,Instances},maps:get(<<"devices">>,Data)),
    case maps:get(once,A,false) of
        true -> ok;
        false -> receive stop_monitor -> ok after maps:get(interval,A,1000) -> loop(Name,A,true,NextPlain,NextInstances,NextNames) end
    end.
render(Data) -> render(Data,false).
render(Data,Color) ->
    Session=maps:get(<<"session">>,Data),Rows=maps:get(<<"devices">>,Data),
    Header=io_lib:format("Session: ~ts  ~ts  (~ts)~n",[safe(maps:get(<<"name">>,Session,<<>>)),safe(maps:get(<<"session">>,Session,<<>>)),safe(maps:get(<<"state">>,Data))]),
    Clock=maps:get(<<"clock">>,Data,#{}),
    Policy=maps:get(<<"offset_policy">>,Clock,#{}),
    Response=case maps:get(<<"offset_ms">>,Policy,null) of
        Ms when is_integer(Ms) -> [integer_to_list(Ms)," ms",case maps:get(<<"ready">>,Policy,false) of true -> [];false -> " (not ready)" end];
        _ -> "N/A"
    end,
    Measured=case {maps:get(<<"measured_ms">>,Policy,null),maps:get(<<"measurement_count">>,Policy,undefined)} of
        {Avg,Count} when is_integer(Avg),is_integer(Count),Count>0 ->
            ["  measured: ",integer_to_list(Avg)," ms average of ",integer_to_list(Count)," sample",
             case Count of 1 -> [];_ -> "s" end];
        {Avg,undefined} when is_integer(Avg) ->
            Values=maps:get(<<"measured">>,Policy,[]),
            ["  measured: ",integer_to_list(Avg)," ms average of ",integer_to_list(length(Values))," Device",
             case length(Values) of 1 -> [];_ -> "s" end];
        _ -> []
    end,
    Names=[device_name(R) || R <- Rows],
    [Header,clock_line(Clock),"  Response time: ",Response,Measured,"\n",
     [row_lines(R,Color,length([N || N <- Names,N=:=device_name(R)])>1) || R <- Rows]].
%% Session time is UTC; each Device reads it itself (time server or its own clock).
clock_line(#{<<"state">> := <<"synchronized">>,<<"utc_time_ns">> := UTC,<<"age_ns">> := Age}=Clock) when is_integer(UTC),is_integer(Age) ->
    Time=calendar:system_time_to_rfc3339(UTC div 1000000,[{unit,millisecond},{offset,"Z"}]),
    Source=case maps:get(<<"source">>,Clock,null) of <<"ntp">> -> maps:get(<<"reference">>,Clock,<<"time server">>);_ -> <<"system clock">> end,
    Error=case maps:get(<<"last_error">>,Clock,null) of null -> [];E -> io_lib:format(" (time server: ~tp)",[E]) end,
    ["Clock: ",Time," UTC | ",safe(Source)," | read ",integer_to_list(Age div 1000000000)," s ago",Error,"\n"];
clock_line(_) -> "Clock: N/A\n".
%% One Device: its name and channels on one line, then only what has content.
row_lines(#{<<"id">> := Id,<<"state">> := State}=R,Color,Duplicate) ->
    Short=binary:part(Id,0,min(12,byte_size(Id))),Name=device_name(R),
    Title=case Duplicate of true -> [Name," (",Short,")"];false -> Name end,
    Channels=case maps:find(<<"capabilities">>,R) of
        error -> tint(State,safe(State),Color);
        {ok,C} ->
            Audio=maps:get(<<"audio">>,C,#{}),
            case map_size(Audio) of
                0 -> tint(<<"disabled">>,"no audio",Color);
                _ -> lists:join("  ",[channel(K,maps:get(K,Audio,#{}),State,Color) || K <- [<<"speaker">>,<<"microphone">>,<<"broadcast">>]])
            end
    end,
    [paint("1",Title,Color),"   ",Channels,"\n",diagnostic_lines(R,Color),paint("90",[lists:duplicate(83,$-),"\n"],Color)].
channel(K,E,Default,Color) ->
    Status=maps:get(<<"state">>,E,Default),
    Levels=case maps:find(<<"peak_db">>,E) of
        {ok,Peak} when is_number(Peak) -> [" ",level(Peak),"/",level(maps:get(<<"rms_db">>,E,null))," dB"];
        _ -> []
    end,
    tint(Status,[K," ",case Status of <<"disabled">> -> "off";_ -> safe(Status) end,Levels],Color).
diagnostic_lines(R,Color) ->
    Caps=maps:get(<<"capabilities">>,R,#{}),
    Errors=[tint(<<"error">>,["  ! ",K,": ",safe(Error),"\n"],Color) ||
        {K,Entry} <- maps:to_list(maps:get(<<"audio">>,Caps,#{})),
        Error <- [maps:get(<<"error">>,Entry,<<>>)],Error=/=<<>>,maps:get(<<"state">>,Entry,undefined)=/=<<"unsupported">>],
    case maps:find(<<"audio_diagnostics">>,Caps) of
        error -> [Errors,case maps:is_key(<<"audio">>,Caps) of
            true -> paint("90","  diagnostics unavailable\n",Color);
            false -> [] end];
        {ok,D} ->
            Analysis=case maps:get(<<"diagnostics.analysis">>,D,true) of
                false -> "  audio analysis off\n";
                true -> [io_lib:format("  clock ~ts (~ts ns)  sample ~ts ms~n",[safe(maps:get(<<"clock.state">>,D,<<"unavailable">>)),
                            number(maps:get(<<"clock.remaining_correction_ns">>,D,null)),number(maps:get(<<"diagnostics.age_ms">>,D,null))]),
                         mixer_line(D),peak_gain_line(D),engine_lines(D)]
            end,
            [Analysis,Errors,failure_history_line(D,maps:get(<<"audio_trace">>,Caps,#{}),Color)]
    end.
mixer_line(D) ->
    case maps:is_key(<<"mixer.rendered">>,D) of
        false -> [];
        true -> io_lib:format("  mixer ~ts rendered  ~ts dropped  ~ts queued  ~ts clipped~n",[
            number(maps:get(K,D,null)) || K <- [<<"mixer.rendered">>,<<"mixer.dropped">>,<<"mixer.queued_blocks">>,<<"mixer.clipped_frames">>]])
    end.
peak_gain_line(#{<<"mixer.peak_gain_cdb">> := Gain}) when is_integer(Gain),Gain>= -9600,Gain=<0 ->
    io_lib:format("  mix peak gain: ~.1f dB~n",[Gain/100]);
peak_gain_line(_) -> [].
%% These totals outlive individual media attempts and describe history.
failure_history_line(D,Trace,Color) ->
    Failures=[io_lib:format("~ts: ~B",[safe(K),V]) ||
        {K,V} <- lists:sort(maps:to_list(D)),is_integer(V),V>0,binary:match(K,<<".failure.">>)=/=nomatch],
    Recent=case lists:sort(fun(A,B) -> maps:get(<<"age_ms">>,A)<maps:get(<<"age_ms">>,B) end,maps:values(Trace)) of
        [E|_] -> [" (last ",safe(maps:get(<<"stage">>,E)),"/",safe(maps:get(<<"reason">>,E))," ",
                  number(maps:get(<<"age_ms">>,E) div 1000)," s ago)"];
        [] -> []
    end,
    case Failures of
        [] -> [];
        _ -> paint("90",["  Failure history: ",lists:join("  ",Failures),Recent,"\n"],Color)
    end.
%% The audio engine's own counters: receiving and/or sending streams.
engine_lines(D) ->
    N=fun(K) -> number(maps:get(<<"transport.",K/binary>>,D,null)) end,
    Receive=case maps:is_key(<<"transport.packets">>,D) of
        false -> [];
        true -> io_lib:format("  in  ~ts pkts  ~ts late  ~ts missing  ~ts jumps  ~ts dup  ~ts rej  ~ts/~ts recovered  err ~ts/~ts us~n",
            [N(K) || K <- [<<"packets">>,<<"late">>,<<"missing_frames">>,<<"jumps">>,<<"duplicates">>,<<"rejected">>,
                          <<"recovered">>,<<"nacks">>,<<"schedule_error_mean_us">>,<<"schedule_error_max_us">>]])
    end,
    Send=case maps:is_key(<<"transport.sent">>,D) of
        false -> [];
        true -> io_lib:format("  out ~ts sends  ~ts resent  ~ts errors  ~ts overruns  ~ts jumps  err ~ts us~n",
            [N(K) || K <- [<<"sent">>,<<"retransmits">>,<<"send_errors">>,<<"capture_overruns">>,<<"capture_jumps">>,<<"capture_error_max_us">>]])
    end,
    %% How each connection travels: same network, through NATs, or via TURN.
    Path=case lists:sum([maps:get(<<"transport.path_",K/binary>>,D,0) || K <- [<<"direct">>,<<"nat">>,<<"relay">>,<<"none">>]]) of
        0 -> [];
        _ -> io_lib:format("  path ~ts direct  ~ts through NAT  ~ts relayed  ~ts not connected  ~ts re-routes  ~ts ICE failures~n",
            [N(K) || K <- [<<"path_direct">>,<<"path_nat">>,<<"path_relay">>,<<"path_none">>,<<"route_changes">>,<<"ice_failures">>]])
    end,
    [Receive,Send,Path].
device_name(#{<<"id">> := Id}=R) ->
    case maps:get(<<"name">>,R,<<>>) of
        <<>> -> binary:part(Id,0,min(12,byte_size(Id)));
        N -> safe(N)
    end.
terminal_color() ->
    os:getenv("NO_COLOR")=:=false andalso os:getenv("TERM")=/="dumb" andalso
        case io:columns() of {ok,_} -> true;_ -> false end.
tint(State,Text,Color) ->
    Code=case State of
        <<"running">> -> "32";
        <<"disabled">> -> "90";
        <<"error">> -> "31";
        <<"unavailable">> -> "31";
        _ -> "33"
    end,paint(Code,Text,Color).
paint(Code,Text,true) -> [<<27,"[">>,Code,"m",Text,<<27,"[0m">>];
paint(_,Text,false) -> Text.
level(N) when is_number(N) -> io_lib:format("~.1f",[float(N)]);
level(_) -> "N/A".
number(true) -> "running";
number(false) -> "stopped";
number(N) when is_integer(N) -> integer_to_list(N);
number(_) -> "N/A".
fail(Text) -> throw({cli_error,1,#{error => Text}}).

safe(Text) ->
    case unicode:characters_to_list(Text) of
        Chars when is_list(Chars) -> [case C>=32 andalso not (C>=127 andalso C<160) of true -> C;false -> $? end || C <- Chars];
        _ -> "?"
    end.
