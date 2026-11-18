%% Console projection of ordinary Buffee-member observations. No PCM or audio I/O.
-module(ba_cli_monitor).
-export([run/2,run_local/1,render/1,render/2,invitation_path/2]).
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
            io:format(standard_error,"Monitoring local Device ~s and its current Buffee. Ctrl-C exits this view.~n",[Selected]),
            Selected;
        error ->
            io:put_chars(standard_error,"Connecting Buffee monitor (audio stays disabled)...\n"),
            Observer=choose(A,Root),
            io:format(standard_error,"Monitoring through Device ~s. Audio disabled. Ctrl-C exits this view; Device stays connected.~n",[Observer]),
            Observer
    end,
    loop(Name,A,maps:get(metrics,A,false),#{},#{},#{}).
choose(A,Root) ->
    Path=invitation_path(A,Root),
    Parsed=case file:read_file(Path) of
        {ok,B} -> Link=string:trim(B),try {_,I}=ba_buffee_passport:parse_invitation(Link),{Link,I} catch _:_ -> invalid end;
        _ -> invalid
    end,
    case Parsed of
        {Invitation,Body} ->
            Id=maps:get(<<"buffee">>,Body),Name="ba-monitor-"++binary_to_list(Id),
            ensure(Name,Invitation,Id,A,Root),Name;
        invalid ->
            Candidates=case maps:find(devicename,A) of {ok,Selected} -> [Selected];error -> [Candidate || Candidate <- ba_cli_store:names(),lists:prefix("ba-monitor-",Candidate)] end,
            Live=[N || N <- Candidates,live_observer(N)],
            case Live of
                [N] -> io:put_chars(standard_error,"Using existing authorized observer; no new invitation is required.\n"),N;
                [] -> fail(<<"No active observer or valid saved invitation. Supply a fresh --invitation-file. No Buffee was created.">>);
                _ -> fail(<<"Several observers are active. Select one with --devicename or a valid --invitation-file.">>)
            end
    end.
live_observer(Name) ->
    try
        R=ba_cli:request(Name,#{<<"method">> => <<"snapshot">>}),
        maps:get(<<"observer">>,maps:get(<<"managed">>,R),false) andalso
        maps:get(<<"state">>,maps:get(<<"buffee">>,R))=:=<<"authorized">>
    catch _:_ -> false end.

invitation_path(A,Root) -> maps:get(invitation_file,A,filename:join([Root,"builds/CLI/private/monitor-invitation.txt"])).
ensure(Name,Link,Id,A,Root) ->
    case ba_cli_store:read(Name) of
        {error,not_running} ->
            ba_cli:new_device(#{devicename => Name,enable => "",createbuffee => false,joinbuffee => binary_to_list(Link),
                observer => true,until => "admitted",timeout => maps:get(timeout,A,"120s")},Root),ok;
        {ok,_} ->
            R=ba_cli:request(Name,#{<<"method">> => <<"snapshot">>}),
            case maps:get(<<"observer">>,maps:get(<<"managed">>,R),false) of true -> ok;false -> fail(<<"Reserved monitor name is owned by a non-observer Device.">>) end,
            Buffee=maps:get(<<"buffee">>,R),
            case {maps:get(<<"state">>,Buffee),maps:get(<<"buffee">>,Buffee,null)} of
                {<<"idle">>,_} -> ba_cli:request(Name,#{<<"method">> => <<"join_buffee">>,<<"invitation">> => Link});
                {<<"authorized">>,Id} -> ok;
                {_,Id} ->
                    ba_cli:request(Name,#{<<"method">> => <<"leave_buffee">>}),
                    ba_cli:request(Name,#{<<"method">> => <<"join_buffee">>,<<"invitation">> => Link});
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
                <<"idle">> -> fail(<<"The saved gathering is no longer active. Supply a valid invitation from the current Buffee (--invitation-file PATH).">>);
                <<"revoked">> -> fail(<<"Admission was denied. Check revocation and that the Owner is online.">>);
                <<"ended">> -> fail(<<"The saved Buffee ended. A new Buffee needs a valid invitation.">>);
                _ -> ok
            end,
            case State=:=LastState of
                true -> ok;
                false -> io:format(standard_error,"Waiting for admission (~ts); checking the saved invitation's gathering...~n",[safe(State)])
            end,
            case erlang:monotonic_time(millisecond)>=Until of
                true -> fail(<<"Timed out joining the saved Buffee. Keep its Owner online or supply a fresh invitation from the current Buffee.">>);
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
    Buffee=maps:get(<<"buffee">>,Data),Rows=maps:get(<<"devices">>,Data),
    Header=io_lib:format("Session: ~ts  ~ts  (~ts)~n",[safe(maps:get(<<"name">>,Buffee,<<>>)),safe(maps:get(<<"buffee">>,Buffee,<<>>)),safe(maps:get(<<"state">>,Data))]),
    Policy=maps:get(<<"offset_policy">>,maps:get(<<"clock">>,Data,#{}),#{}),
    Response=case maps:get(<<"offset_ms">>,Policy,null) of
        Ms when is_integer(Ms) -> [integer_to_list(Ms)," ms",case maps:get(<<"ready">>,Policy,false) of true -> [];false -> " (not ready)" end];
        _ -> "N/A"
    end,
    Names=[device_name(R) || R <- Rows],
    [Header,master_clock_line(maps:get(<<"clock">>,Data,#{}),Rows),
     "Response time: ",Response,"\n","  CHANNEL     STATE                  PEAK dBFS  RMS dBFS  STAGE        AGE ms\n",
     [row_lines(R,Color,length([N || N <- Names,N=:=device_name(R)])>1) || R <- Rows],
     "N/A = unavailable; receive_max = loudest received Source, before physical speaker output; output_submitted = PCM handed to binding, not proof of audible sound.\n"].
master_clock_line(Clock,Rows) ->
    try
        #{<<"device">> := Id,<<"utc_time_ns">> := Value,<<"age_ms">> := Age,<<"state">> := State}=maps:get(<<"master_clock">>,Clock),
        true=is_integer(Age) andalso Age>=0,
        Ms=ba_buffee_time_protocol:integer(Value) div 1000000,
        UTC=calendar:system_time_to_rfc3339(Ms,[{unit,millisecond},{offset,"Z"}]),
        Name=case [R || #{<<"id">> := I}=R <- Rows,I=:=Id] of [R] -> device_name(R);_ -> device_name(#{<<"id">> => Id}) end,
        ["Master clock: ",UTC," | ",Name," | sample age: ",integer_to_list(Age)," ms",
            case State of <<"fresh">> -> [];_ -> " (stale)" end,"\n"]
    catch _:_ -> "Master clock: N/A\n" end.
row_lines(#{<<"id">> := Id,<<"state">> := State}=R,Color,Duplicate) ->
    Short=binary:part(Id,0,min(12,byte_size(Id))),Name=device_name(R),
    Title=case Duplicate of true -> [Name," (",Short,")"];false -> Name end,
    Lines=case maps:find(<<"capabilities">>,R) of
        error -> tint(State,["  ",safe(State),"\n"],Color);
        {ok,C} ->
            Audio=maps:get(<<"audio">>,C,#{}),
            case map_size(Audio) of
                0 -> tint(<<"disabled">>,"  No audio capabilities\n",Color);
                _ -> [begin E=maps:get(K,Audio,#{}),Status=maps:get(<<"state">>,E,State),
                    Line=case Status of
                        <<"disabled">> -> io_lib:format("  ~-10ts  ~ts~n",[K,Status]);
                        _ -> io_lib:format("  ~-10ts  ~-21ts  ~9ts  ~8ts  ~-11ts  ~ts~n",[K,
                            safe(Status),level(maps:get(<<"peak_db">>,E,null)),level(maps:get(<<"rms_db">>,E,null)),
                            safe(maps:get(<<"meter_stage">>,E,<<"N/A">>)),number(maps:get(<<"meter_age_ms">>,E,null))])
                    end,tint(Status,Line,Color)
                end || K <- [<<"speaker">>,<<"microphone">>,<<"broadcast">>]]
            end
    end,
    [paint("1",[Title,"\n"],Color),Lines,diagnostic_lines(R,Color),paint("90",[lists:duplicate(83,$-),"\n"],Color)].
diagnostic_lines(R,Color) ->
    Caps=maps:get(<<"capabilities">>,R,#{}),
    Errors=[tint(<<"error">>,["  ! ",K,": ",safe(Error),"\n"],Color) ||
        {K,Entry} <- maps:to_list(maps:get(<<"audio">>,Caps,#{})),
        Error <- [maps:get(<<"error">>,Entry,<<>>)],Error=/=<<>>],
    case maps:find(<<"audio_diagnostics">>,Caps) of
        error -> [Errors,case maps:is_key(<<"audio">>,Caps) of
            true -> paint("90","  Playback diagnostics: unavailable (Device update required)\n",Color);
            false -> [] end];
        {ok,D} ->
            Clock=io_lib:format("  Clock: ~ts  correction: ~ts ns~n",[
                safe(maps:get(<<"clock.state">>,D,<<"unavailable">>)),number(maps:get(<<"clock.remaining_correction_ns">>,D,null))]),
            Playback=case maps:is_key(<<"mixer.rendered">>,D) of
                false -> [];
                true -> io_lib:format("  Mixer: ~ts rendered  ~ts dropped  ~ts queued  ~ts clipped frames~n",[
                    number(maps:get(K,D,null)) || K <- [<<"mixer.rendered">>,<<"mixer.dropped">>,<<"mixer.queued_blocks">>,<<"mixer.clipped_frames">>]])
            end,
            Failures=[tint(<<"error">>,io_lib:format("  ! ~ts: ~B (total)~n",[safe(K),V]),Color) ||
                {K,V} <- lists:sort(maps:to_list(D)),is_integer(V),V>0,binary:match(K,<<".failure.">>)=/=nomatch],
            MeterLines=[io_lib:format("  ~ts: ~ts peak / ~ts RMS dBFS  age ~ts ms~n",[
                safe(K),level(maps:get(<<"peak_db">>,E)),level(maps:get(<<"rms_db">>,E)),number(maps:get(<<"meter_age_ms">>,E))]) ||
                {K,E} <- lists:sort(maps:to_list(maps:get(<<"audio_meters">>,Caps,#{})))],
            [Errors,MeterLines,case maps:get(<<"diagnostics.analysis">>,D,true) of
                false -> "  Audio analysis: OFF\n";
                true -> ["  Diagnostic sample age: ",number(maps:get(<<"diagnostics.age_ms">>,D,null))," ms\n",Clock,Playback,transport_lines(D),output_line(D)]
            end,case maps:get(<<"diagnostics.meters">>,D,true) of false -> "  Audio meters: OFF\n";true -> [] end,Failures,
            [["  Recent: ",safe(maps:get(<<"stage">>,E))," / ",safe(maps:get(<<"reason">>,E)),
              " (",number(maps:get(<<"age_ms">>,E))," ms ago)\n"] || E <- lists:sublist(lists:sort(fun(A,B) -> maps:get(<<"age_ms">>,A)<maps:get(<<"age_ms">>,B) end,maps:values(maps:get(<<"audio_trace">>,Caps,#{}))),3)]]
    end.
%% Connection setup of current transports, e.g. "2 ice_checking" with the
%% candidate types each side has seen and the STUN/TURN URLs configured.
transport_lines(D) ->
    Group=fun(Prefix) ->
        Size=byte_size(Prefix),
        lists:join(" ",[[number(V)," ",safe(binary:part(K,Size,byte_size(K)-Size))] ||
            {K,V} <- lists:sort(maps:to_list(D)),is_integer(V),V>0,byte_size(K)>Size,binary:part(K,0,Size)=:=Prefix])
    end,
    case Group(<<"transport.stage.">>) of
        [] -> [];
        Stages ->
            None=fun([]) -> "none";(L) -> L end,
            ["  Transport setup: ",Stages,"  (",number(maps:get(<<"transport.open">>,D,0)),"/",
             number(maps:get(<<"transport.sessions">>,D,0))," open)\n",
             "    candidates local: ",None(Group(<<"transport.local_candidates.">>)),
             "  remote: ",None(Group(<<"transport.remote_candidates.">>)),
             "  ICE servers: ",number(maps:get(<<"transport.ice.stun_urls">>,D,0))," STUN / ",
             number(maps:get(<<"transport.ice.turn_urls">>,D,0))," TURN\n"]
    end.
output_line(#{<<"output.supported">> := true}=D) ->
    io_lib:format("  Output (~ts): engine ~ts  player ~ts  route ~ts  volume ~ts/1000~n    ~ts scheduled / ~ts completed frames  ~ts queued / ~ts rejected buffers  stats age ~ts ms~n",[
        safe(maps:get(<<"output.backend">>,D,<<"unknown">>)),
        number(maps:get(<<"output.engine_running">>,D,null)),number(maps:get(<<"output.player_running">>,D,null)),
        safe(maps:get(<<"output.route">>,D,<<"unavailable">>)),number(maps:get(<<"output.volume_milli">>,D,null)),
        number(maps:get(<<"output.scheduled_frames">>,D,null)),number(maps:get(<<"output.completed_frames">>,D,null)),
        number(maps:get(<<"output.queued_buffers">>,D,null)),number(maps:get(<<"output.rejected_buffers">>,D,null)),
        number(maps:get(<<"output.stats_age_ms">>,D,null))]);
output_line(_) -> "  Native output diagnostics: unavailable\n".
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
