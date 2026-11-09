%% Console projection of ordinary Swarm-member observations. No PCM or audio I/O.
-module(ba_cli_monitor).
-export([run/2,render/1,invitation_path/2]).
run(A,Root) ->
    case maps:get(all,A,false) of true -> ok;false -> fail(<<"Use beam-audio monitor --all.">>) end,
    _=ba_cli:timeout(A),
    io:put_chars(standard_error,"Connecting Swarm monitor (audio stays disabled)...\n"),
    Name=choose(A,Root),
    io:format(standard_error,"Monitoring through Device ~s. Audio disabled. Ctrl-C exits this view; Device stays connected.~n",[Name]),
    loop(Name,A,false,#{},#{}).
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
                <<"idle">> -> fail(<<"The saved gathering is no longer active. Supply a fresh unused invitation from the current Swarm (--invitation-file PATH).">>);
                <<"revoked">> -> fail(<<"Admission was denied. The invitation may already be claimed; use a fresh unused invitation.">>);
                <<"ended">> -> fail(<<"The saved Swarm ended. A new Swarm needs a fresh unused invitation.">>);
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

loop(Name,A,Metrics,Plain,Instances) ->
    Now=erlang:monotonic_time(millisecond),
    Skip=[Id || {Id,#{retry := Until}} <- maps:to_list(Plain),Now<Until],
    R=ba_cli:request(Name,#{<<"method">> => <<"monitor">>,<<"metrics">> => Metrics,<<"plain">> => Skip}),
    Data=maps:get(<<"result">>,R),
    case maps:get(json,A,false) of
        true -> io:put_chars([json:encode(Data),$\n]);
        false ->
            case io:columns() of {ok,_} -> io:put_chars(<<27,"[H",27,"[2J">>);_ -> ok end,
            io:put_chars(render(Data))
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
        false -> receive stop_monitor -> ok after maps:get(interval,A,1000) -> loop(Name,A,true,NextPlain,NextInstances) end
    end.
render(Data) ->
    Swarm=maps:get(<<"swarm">>,Data),
    Header=io_lib:format("Swarm: ~ts  ~ts  (~ts)~n",[safe(maps:get(<<"name">>,Swarm,<<>>)),maps:get(<<"swarm">>,Swarm,<<>>),safe(maps:get(<<"state">>,Data))]),
    [Header,"DEVICE        CHANNEL     STATE                  PEAK dBFS  RMS dBFS  STAGE        AGE ms\n",
     [row_lines(R) || R <- maps:get(<<"devices">>,Data)],
     "N/A = unavailable/not exposed; receive_max is max received Source, not physical speaker output.\n"].
row_lines(#{<<"id">> := Id,<<"state">> := State}=R) ->
    Short=binary:part(Id,0,min(12,byte_size(Id))),
    case maps:find(<<"capabilities">>,R) of
        error -> io_lib:format("~-12ts  ~-10ts  ~ts~n",[Short,<<"-">>,State]);
        {ok,C} ->
            Audio=maps:get(<<"audio">>,C,#{}),
            case map_size(Audio) of
                0 -> io_lib:format("~-12ts  ~-10ts  ~ts~n",[Short,<<"-">>,<<"No audio capabilities">>]);
                _ -> [begin E=maps:get(K,Audio,#{}),
                    io_lib:format("~-12ts  ~-10ts  ~-21ts  ~9ts  ~8ts  ~-11ts  ~ts~n",[Short,K,
                        safe(maps:get(<<"state">>,E,State)),level(maps:get(<<"peak_db">>,E,null)),level(maps:get(<<"rms_db">>,E,null)),
                        maps:get(<<"meter_stage">>,E,<<"N/A">>),number(maps:get(<<"meter_age_ms">>,E,null))])
                end || K <- [<<"speaker">>,<<"microphone">>,<<"broadcast">>]]
            end
    end.
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
