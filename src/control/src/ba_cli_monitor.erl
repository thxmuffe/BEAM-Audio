%% Console projection of ordinary Swarm-member observations. No PCM or audio I/O.
-module(ba_cli_monitor).
-export([run/2,render/1,render/2,invitation_path/2]).
run(A,Root) ->
    case maps:get(all,A,false) of true -> ok;false -> fail(<<"Use beamaudio monitor --all.">>) end,
    _=ba_cli:timeout(A),
    Name=case maps:find(devicename,A) of
        {ok,Selected} ->
            _=ba_cli:request(Selected,#{<<"method">> => <<"snapshot">>}),
            io:format(standard_error,"Monitoring local Device ~s and its current Swarm. Ctrl-C exits this view.~n",[Selected]),
            Selected;
        error ->
            io:put_chars(standard_error,"Connecting Swarm monitor (audio stays disabled)...\n"),
            Observer=choose(A,Root),
            io:format(standard_error,"Monitoring through Device ~s. Audio disabled. Ctrl-C exits this view; Device stays connected.~n",[Observer]),
            Observer
    end,
    loop(Name,A,false,#{},#{},#{}).
choose(A,Root) ->
    Path=invitation_path(A,Root),
    Parsed=case file:read_file(Path) of
        {ok,B} -> Link=string:trim(B),try {_,I}=ba_swarm_passport:parse_invitation(Link),{Link,I} catch _:_ -> invalid end;
        _ -> invalid
    end,
    case Parsed of
        {Invitation,Body} ->
            Id=maps:get(<<"swarm">>,Body),Name="ba-monitor-"++binary_to_list(Id),
            ensure(Name,Invitation,Id,A,Root),Name;
        invalid ->
            Candidates=case maps:find(devicename,A) of {ok,Selected} -> [Selected];error -> [Candidate || Candidate <- ba_cli_store:names(),lists:prefix("ba-monitor-",Candidate)] end,
            Live=[N || N <- Candidates,live_observer(N)],
            case Live of
                [N] -> io:put_chars(standard_error,"Using existing authorized observer; no new invitation is required.\n"),N;
                [] -> fail(<<"No active observer or valid saved invitation. Supply a fresh --invitation-file. No Swarm was created.">>);
                _ -> fail(<<"Several observers are active. Select one with --devicename or a valid --invitation-file.">>)
            end
    end.
live_observer(Name) ->
    try
        R=ba_cli:request(Name,#{<<"method">> => <<"snapshot">>}),
        maps:get(<<"observer">>,maps:get(<<"managed">>,R),false) andalso
        maps:get(<<"state">>,maps:get(<<"swarm">>,R))=:=<<"authorized">>
    catch _:_ -> false end.

invitation_path(A,Root) -> maps:get(invitation_file,A,filename:join([Root,"builds/CLI/private/monitor-invitation.txt"])).
ensure(Name,Link,Id,A,Root) ->
    case ba_cli_store:read(Name) of
        {error,not_running} ->
            ba_cli:new_device(#{devicename => Name,enable => "",createswarm => false,joinswarm => binary_to_list(Link),
                observer => true,until => "admitted",timeout => maps:get(timeout,A,"120s")},Root),ok;
        {ok,_} ->
            R=ba_cli:request(Name,#{<<"method">> => <<"snapshot">>}),
            case maps:get(<<"observer">>,maps:get(<<"managed">>,R),false) of true -> ok;false -> fail(<<"Reserved monitor name is owned by a non-observer Device.">>) end,
            Swarm=maps:get(<<"swarm">>,R),
            case {maps:get(<<"state">>,Swarm),maps:get(<<"swarm">>,Swarm,null)} of
                {<<"idle">>,_} -> ba_cli:request(Name,#{<<"method">> => <<"join_swarm">>,<<"invitation">> => Link});
                {<<"authorized">>,Id} -> ok;
                {_,Id} ->
                    ba_cli:request(Name,#{<<"method">> => <<"leave_swarm">>}),
                    ba_cli:request(Name,#{<<"method">> => <<"join_swarm">>,<<"invitation">> => Link});
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
                <<"idle">> -> fail(<<"The saved gathering is no longer active. Supply a valid invitation from the current Swarm (--invitation-file PATH).">>);
                <<"revoked">> -> fail(<<"Admission was denied. Check revocation and that the Captain is online.">>);
                <<"ended">> -> fail(<<"The saved Swarm ended. A new Swarm needs a valid invitation.">>);
                _ -> ok
            end,
            case State=:=LastState of
                true -> ok;
                false -> io:format(standard_error,"Waiting for admission (~ts); checking the saved invitation's gathering...~n",[safe(State)])
            end,
            case erlang:monotonic_time(millisecond)>=Until of
                true -> fail(<<"Timed out joining the saved Swarm. Keep its Captain online or supply a fresh invitation from the current Swarm.">>);
                false -> receive after 250 -> ok end,await_admission(Name,Until,State)
            end
    end.

loop(Name,A,Metrics,Plain,Instances,Names) ->
    Now=erlang:monotonic_time(millisecond),
    Skip=[Id || {Id,#{retry := Until}} <- maps:to_list(Plain),Now<Until],
    R=ba_cli:request(Name,#{<<"method">> => <<"monitor">>,<<"metrics">> => Metrics,<<"plain">> => Skip}),
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
    Swarm=maps:get(<<"swarm">>,Data),Rows=maps:get(<<"devices">>,Data),
    Header=io_lib:format("Swarm: ~ts  ~ts  (~ts)~n",[safe(maps:get(<<"name">>,Swarm,<<>>)),safe(maps:get(<<"swarm">>,Swarm,<<>>)),safe(maps:get(<<"state">>,Data))]),
    Names=[device_name(R) || R <- Rows],
    [Header,"  CHANNEL     STATE                  PEAK dBFS  RMS dBFS  STAGE        AGE ms\n",
     [row_lines(R,Color,length([N || N <- Names,N=:=device_name(R)])>1) || R <- Rows],
     "N/A = unavailable; receive_max = loudest received Source, before physical speaker output.\n"].
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
            [Errors,Clock,Playback,Failures]
    end.
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
number(N) when is_integer(N) -> integer_to_list(N);
number(_) -> "N/A".
fail(Text) -> throw({cli_error,1,#{error => Text}}).

safe(Text) ->
    case unicode:characters_to_list(Text) of
        Chars when is_list(Chars) -> [case C>=32 andalso not (C>=127 andalso C<160) of true -> C;false -> $? end || C <- Chars];
        _ -> "?"
    end.
