%% CLI presentation/lifecycle only. Device behavior and readiness live in OTP APIs.
-module(ba_cli).
-export([main/2,spec/1,new_device/2,request/2,timeout/1]).
main(Args,Root) ->
    %% Compact invitations omit the default Reception; parsing needs app defaults
    %% before a Device has been started (notably the monitor invitation file).
    _=application:load(ba_core),
    try case lists:member("--help",Args) of
        true -> io:put_chars(argparse:help(spec(Root),#{progname => "beamaudio",command => [A || A <- Args,A=/="--help"]}));
        false -> case argparse:parse(Args,spec(Root),#{progname => "beamaudio"}) of
            {ok,A,_,#{handler := F}} -> F(A);
            {error,R} -> io:format(standard_error,"~ts~n",[argparse:format_error(R)]),halt(2)
        end
    end
    catch
        throw:{cli_error,Code,Detail} -> io:put_chars(standard_error,[json:encode(Detail),$\n]),halt(Code);
        Class:Reason:Stack ->
            %% Presentation failures belong to this CLI, not the Device's log.
            %% Report locations only: exception terms/arguments may carry secrets.
            Tag=case Reason of ReasonAtom when is_atom(ReasonAtom) -> ReasonAtom;T when is_tuple(T),tuple_size(T)>0,is_atom(element(1,T)) -> element(1,T);_ -> unknown end,
            Trace=[#{module => M,function => F,line => proplists:get_value(line,Info,0)} || {M,F,_,Info} <- Stack],
            logger:remove_handler(default),
            logger:add_handler(default,logger_std_h,#{config => #{type => standard_error,sync_mode_qlen => 0}}),
            logger:error(#{event => cli_failed,class => Class,reason => Tag,locations => Trace}),
            logger_std_h:filesync(default),halt(1)
    end.
spec(Root) ->
    Common=[#{name => devicename,long => "-devicename",type => string},
            #{name => json,long => "-json",action => {store,true},default => false},
            #{name => timeout,long => "-timeout",type => string,default => "120s"}],
    Device=fun(F,Extra) -> #{arguments => Extra,handler => fun(A) -> F(A) end} end,
    #{help => "Real headless BEAM Audio Devices; no UI or Distributed Erlang.",arguments => Common,commands => #{
      "monitor" => #{arguments => [#{name => all,long => "-all",action => {store,true},default => false},
          #{name => invitation_file,long => "-invitation-file",type => string},
          #{name => no_user_state,long => "-no-user-state",action => {store,true},default => false,
            help => "Ignore remembered monitor Session and automatic observer selection; do not save this selection."},
          #{name => once,long => "-once",action => {store,true},default => false},
          #{name => metrics,long => "-metrics",action => {store,true},default => false},
          #{name => interval,long => "-interval",type => {integer,[{min,500},{max,10000}]},default => 1000}],
          handler => fun(A) -> ba_cli_monitor:run(A,Root) end},
      "new" => #{commands => #{"device" => Device(fun(A) -> emit(new_device(A,Root)) end,
          [#{name => next_instance,long => "-next-instance",action => {store,true},default => false},
           #{name => createsession,long => "-createsession",action => {store,true},default => false},
           #{name => joinsession,long => "-joinsession",type => string},
           #{name => enable,long => "-enable",type => string},
           #{name => desk,long => "-desk",type => string},
           #{name => until,long => "-wait",type => {string,["endpoint","admitted","ready"]},default => "admitted"},
           #{name => web_assets,long => "-web-assets",type => string},
           #{name => web_port,long => "-web-port",type => {integer,[{min,0},{max,65535}]},default => 8766}])}},
      "inspect" => #{commands => #{
          "logs" => Device(fun download_log/1,
              [#{name => deviceid,long => "-deviceid",type => string,required => true},
               #{name => output,long => "-output",type => string,required => true},
               #{name => log,long => "-log",type => string,default => "runtime.log"}]),
          "device" => Device(fun(A) ->
              Command=case maps:find(deviceid,A) of
                  error -> #{<<"method">> => <<"snapshot">>};
                  {ok,Id} -> #{<<"method">> => <<"inspect">>,<<"device">> => list_to_binary(Id)}
              end,
              emit(request(one_name(A),Command))
          end,[#{name => deviceid,long => "-deviceid",type => string}]),
          "session" => Device(fun inspect_session/1,[#{name => sessionid,long => "-sessionid",type => string,required => true}])}},
      "get" => #{commands => #{
          "methods" => #{handler => fun(_) -> emit(ba_device_api:methods()) end},
          "web" => Device(fun(A) ->
              R=request(one_name(A),#{<<"method">> => <<"snapshot">>}),
              case maps:get(<<"web_url">>,maps:get(<<"managed">>,R),null) of
                  null -> fail(1,<<"This Device has no web service. Start it with --web-assets DIR.">>);
                  URL -> scalar(URL,A)
              end
          end,[]),
          "session" => Device(fun(A) -> scalar(get_session(A),A) end,[]),
          "invitation" => Device(fun(A) -> R=request(one_name(A),#{<<"method">> => <<"invitation">>}),scalar(maps:get(<<"result">>,R),A) end,[])}},
      "history" => #{commands => #{"device" => Device(fun(A) -> emit(request(one_name(A),#{<<"method">> => <<"configuration">>})) end,[])}},
      "undo" => #{commands => #{"device" => Device(fun(A) -> history_action(A,<<"undo">>) end,[])}},
      "redo" => #{commands => #{"device" => Device(fun(A) -> history_action(A,<<"redo">>) end,[])}},
      "set" => #{commands => #{"device" => Device(fun set_device/1,
          [#{name => enable,long => "-enable",type => string,default => ""},#{name => disable,long => "-disable",type => string,default => ""}])}},
      "forget" => #{commands => #{"session" => Device(fun forget_session/1,
          [#{name => sessionid,long => "-sessionid",type => string,required => true}])}},
      "call" => #{commands => #{"device" => Device(fun call_device/1,
          [#{name => request,long => "-request",type => string,default => "-",
             help => "Device API JSON object; omit or use - to read standard input through EOF."}])}},
      "wait" => #{commands => #{"device" => Device(fun(A) -> emit(wait(names(A),maps:get(until,A),timeout(A))) end,
          [#{name => until,long => "-until",type => {string,["endpoint","admitted","ready","audio-flowing"]},default => "ready"}])}},
      "stop" => #{commands => #{"device" => Device(fun(A) -> stop(A,<<"stop">>) end,[#{name => all,long => "-all",action => {store,true},default => false}])}},
      "kill" => #{commands => #{"device" => Device(fun(A) -> stop(A,<<"kill">>) end,[#{name => all,long => "-all",action => {store,true},default => false}])}}
    }}.
new_device(A,Root) ->
    BaseName=one_name(A),Enabled=capabilities(maps:get(enable,A,"")),Timeout=timeout(A),
    Create=maps:get(createsession,A),Join=maps:get(joinsession,A,undefined),
    case Create andalso Join=/=undefined of true -> fail(2,<<"Choose createsession or joinsession, not both.">>);false -> ok end,
    %% Observation and control are platform independent; only the CLI's own
    %% audio helpers are macOS builds so far.
    case Enabled=/=[] andalso os:type()=/={unix,darwin} of
        true -> fail(2,<<"CLI audio capabilities (speaker, mic, broadcast) currently need the macOS native helpers. Audio-off Devices and the monitor work on every platform.">>);
        false -> ok
    end,
    case Enabled=/=[] andalso not filelib:is_regular(filename:join([Root,"builds/CLI","ba_audio_engine"])) of
        true -> fail(2,<<"Missing audio engine; run bash src/Tools/CLI/build.sh.">>);
        false -> ok
    end,
    Instance=binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(16))),
    %% Unix uses an owner-only socket. Windows OTP has no AF_UNIX in gen_tcp, so
    %% the Device publishes a loopback port instead; every request still needs
    %% the random instance secret from the owner's private process record.
    Endpoint=case os:type() of
        {win32,_} -> #{};
        _ -> #{socket => list_to_binary(filename:join("/tmp","ba-device-"++Instance++".sock"))}
    end,
    Mode=case {Create,Join} of {true,_} -> <<"create">>;{_,undefined} -> <<"idle">>;_ -> <<"join">> end,
    C0=Endpoint#{instance => list_to_binary(Instance),name => list_to_binary(BaseName),mode => Mode,enabled => case maps:is_key(enable,A) of true -> Enabled;false -> null end,desk => case maps:find(desk,A) of {ok,Desk} -> list_to_binary(Desk);error -> null end,
        observer => maps:get(observer,A,false),invitation => case Join of undefined -> null;_ -> list_to_binary(Join) end},
    Candidate=case maps:find(web_assets,A) of
        error -> C0;
        {ok,Assets} ->
            case filelib:is_dir(Assets) andalso filelib:is_regular(filename:join([Root,
                    "builds/intermediates/DeviceWeb/default/lib/ba_device_web/ebin/ba_device_web.app"])) of
                true -> C0#{web => #{assets => list_to_binary(filename:absname(Assets)),port => maps:get(web_port,A,8766)}};
                false -> fail(2,<<"Check --web-assets and build the service: bash src/Services/DeviceWeb/build.sh.">>)
            end
    end,
    {Name,D}=case ba_cli_store:reserve(BaseName,maps:get(next_instance,A,false),maps:with([instance,name,socket],Candidate)) of
        {ok,N,Directory} -> {N,Directory};
        {error,already_running} -> fail(1,#{error => <<"Device is already running, starting, or has a stale process record. Inspect/stop it before retrying.">>,device => BaseName});
        {error,R} -> fail(1,R)
    end,
    C=Candidate#{name := list_to_binary(Name)},Record=filename:join(D,"running.json"),
    try
        ok=ba_cli_store:write(filename:join(D,"launch.json"),C),
        Erl=os:find_executable("erl"),
        Paths=filelib:wildcard(filename:join([Root,"builds/intermediates/control/default/lib","*","ebin"]))++
              case maps:is_key(web,C) of
                  true -> filelib:wildcard(filename:join([Root,"builds/intermediates/DeviceWeb/default/lib","*","ebin"]));
                  false -> []
              end,
        Args=["+S","2:2","+SDcpu","1","+SDio","1","-detached","-noshell","-noinput","-start_epmd","false","-pa"]++Paths++
             ["-s","ba_cli_device","boot","-extra",D,Instance,Root],
        Port=open_port({spawn_executable,Erl},[binary,exit_status,{env,[{"BA_IDENTITY_SEED",false},{"ERL_CRASH_DUMP",filename:join(D,"erl_crash.dump")} ]},{args,Args}]),
        receive {Port,{exit_status,0}} -> ok;{Port,{exit_status,_}} -> error(runtime_launch_failed) after 5000 -> error(runtime_launch_timeout) end
    catch _:_ -> ba_cli_store:remove(Record),ba_cli_store:remove(filename:join(D,"launch.json")),fail(1,<<"Could not launch Device runtime.">>) end,
    Predicate=case Mode of <<"idle">> -> "endpoint";_ -> maps:get(until,A) end,
    wait([Name],Predicate,Timeout).
request(N,Command) ->
    case ba_cli_store:read(N) of
        {ok,R} -> case ba_cli_device:call(R,Command) of
            {ok,#{<<"error">> := null}=Reply} -> Reply;
            {ok,Reply} -> fail(1,#{device => list_to_binary(N),error => maps:get(<<"error">>,Reply,<<"Device failed.">>)});
            {error,_} -> fail(1,#{device => list_to_binary(N),error => <<"Device endpoint unavailable; runtime may have stopped. Inspect runtime.log and the process record.">>})
        end;
        {error,R} -> fail(1,#{device => list_to_binary(N),error => R})
    end.
check_startup(#{<<"managed">> := #{<<"startup_error">> := E}}) when E=/=null -> fail(1,E);
check_startup(_) -> ok.
wait(Ns,Predicate,Timeout) -> wait_loop(Ns,Predicate,erlang:monotonic_time(millisecond)+Timeout,#{},0).
wait_loop(Ns,P,Until,Previous,Stable) ->
    Views=maps:from_list([{list_to_binary(N),poll(N,maps:get(list_to_binary(N),Previous,#{}))} || N <- Ns]),
    Ready=lists:all(fun(V) -> maps:get(<<"satisfied">>,V,false) end,[predicate(P,V) || V <- maps:values(Views)]),
    case {Ready,Stable,erlang:monotonic_time(millisecond)>=Until} of
        {true,_,_} when P=/="audio-flowing" -> #{state => ready,condition => list_to_binary(P),devices => Views};
        {true,S,_} when S>=3 -> #{state => ready,condition => list_to_binary(P),devices => Views};
        {_,_,true} -> fail(1,#{error => readiness_timeout,condition => list_to_binary(P),devices => Views});
        _ ->
            %% Poll shared state predicates; the delay bounds query load, never
            %% substitutes for readiness. Require sustained fresh counter progress.
            receive after 250 -> ok end,
            wait_loop(Ns,P,Until,Views,case Ready of true -> Stable+1;false -> 0 end)
    end.
poll(N,Previous) ->
    case ba_cli_store:read(N) of
        {ok,R} -> case ba_cli_device:call(R,#{<<"method">> => <<"readiness">>,<<"previous">> => maps:get(<<"progress">>,Previous,#{})}) of
            {ok,#{<<"result">> := V}=Reply} -> check_startup(Reply),
                case maps:get(<<"failures">>,V,[]) of [] -> V;Fs -> fail(1,#{device => list_to_binary(N),error => Fs}) end;
            _ -> #{<<"endpoint">> => false}
        end;
        _ -> #{<<"endpoint">> => false}
    end.
predicate(P,V) -> V#{<<"satisfied">> => maps:get(list_to_binary(P),V,false)}.
inspect_session(A) ->
    Id=list_to_binary(maps:get(sessionid,A)),
    Candidates=case maps:find(devicename,A) of {ok,_} -> names(A);error -> ba_cli_store:names() end,
    Views=[R || N <- Candidates,R <- [request(N,#{<<"method">> => <<"snapshot">>})],maps:get(<<"session">>,maps:get(<<"session">>,R,#{}),null)=:=Id],
    case Views of [] -> fail(1,<<"No running authorized local view of that Session. Supply --devicename when needed.">>);_ -> emit(#{session => Id,views => Views}) end.
download_log(A) ->
    Name=one_name(A),Peer=list_to_binary(maps:get(deviceid,A)),
    Query=#{<<"method">> => <<"inspect">>,<<"device">> => Peer,<<"log">> => list_to_binary(maps:get(log,A)),
            <<"offset">> => 0,<<"length">> => 8192},
    First=log_chunk(Name,Query),Path=maps:get(output,A),
    case file:open(Path,[write,binary,exclusive]) of
        {ok,F} ->
            ok=file:change_mode(Path,8#600),
            try
                Size=maps:get(<<"size">>,First),Version=maps:get(<<"version">>,First),
                copy_log(Name,Query,First,F,Size,Version),
                emit(#{file => list_to_binary(Path),bytes => Size})
            catch Class:Reason:Stack -> file:close(F),file:delete(Path),erlang:raise(Class,Reason,Stack)
            after file:close(F) end;
        {error,R} -> fail(1,#{error => R,file => list_to_binary(Path)})
    end.
log_chunk(Name,Query) ->
    case request(Name,Query) of
        #{<<"error">> := null,<<"result">> := Data} -> ok=ba_inspection:validate_reply(Data),Data;
        #{<<"error">> := Error} -> fail(1,Error)
    end.
copy_log(Name,Query,Chunk,F,Size,Version) ->
    case maps:get(<<"version">>,Chunk)=:=Version andalso maps:get(<<"size">>,Chunk)>=Size of
        false -> fail(1,<<"Log rotated or was truncated during download; retry.">>);
        true -> ok
    end,
    Offset=maps:get(<<"offset">>,Query),Data=base64:decode(maps:get(<<"data">>,Chunk)),
    Count=min(byte_size(Data),Size-Offset),
    ok=file:write(F,binary:part(Data,0,Count)),Next=Offset+Count,
    case Next>=Size of
        true -> ok;
        false when Count>0 ->
            Q=Query#{<<"offset">> := Next,<<"length">> := min(8192,Size-Next),<<"version">> => Version},
            copy_log(Name,Q,log_chunk(Name,Q),F,Size,Version);
        false -> fail(1,<<"Log ended before its reported size; retry.">>)
    end.
get_session(A) ->
    R=request(one_name(A),#{<<"method">> => <<"snapshot">>}),
    case maps:get(<<"session">>,maps:get(<<"session">>,R),null) of null -> fail(1,<<"Device has no active Session.">>);Id -> Id end.
set_device(A) ->
    N=one_name(A),On=capabilities(maps:get(enable,A)),Off=capabilities(maps:get(disable,A)),
    case [K || K <- On,lists:member(K,Off)] of [] -> ok;_ -> fail(2,<<"A capability cannot be both enabled and disabled.">>) end,
    Patch=maps:from_list([{K,B} || {Ks,B} <- [{On,true},{Off,false}],K <- Ks]),
    R=request(N,#{<<"method">> => <<"snapshot">>}),
    emit(request(N,#{<<"method">> => <<"capabilities">>,<<"consent">> => Patch,
        <<"expected_revision">> => maps:get(<<"revision">>,maps:get(<<"configuration">>,R)),
        <<"request_id">> => binary:encode_hex(crypto:strong_rand_bytes(16))})).
history_action(A,Method) ->
    N=one_name(A),R=request(N,#{<<"method">> => <<"snapshot">>}),
    emit(request(N,#{<<"method">> => Method,
        <<"expected_revision">> => maps:get(<<"revision">>,maps:get(<<"configuration">>,R)),
        <<"request_id">> => binary:encode_hex(crypto:strong_rand_bytes(16))})).

forget_session(A) ->
    Id=list_to_binary(maps:get(sessionid,A)),
    case ba_hex:valid(Id,32) of
        true -> emit(request(one_name(A),#{<<"method">> => <<"forget_saved_session">>,<<"entry">> => Id}));
        false -> fail(2,<<"Supply a Session ID of 32 hexadecimal characters.">>)
    end.

call_device(A) ->
    Name=one_name(A),
    Data=case maps:get(request,A) of
        "-" ->
            ok=io:setopts(standard_io,[binary,{encoding,utf8}]),
            case io:get_chars(standard_io,"",16385) of
                Bytes when is_binary(Bytes) -> Bytes;
                _ -> fail(2,<<"Supply one Device API JSON object on standard input.">>)
            end;
        Text -> unicode:characters_to_binary(Text)
    end,
    case byte_size(Data)=<16384 of true -> ok;false -> fail(2,<<"Device API JSON requests are limited to 16 KiB.">>) end,
    Command=try json:decode(Data) of
        #{<<"method">> := Method}=R when is_binary(Method) ->
            case lists:member(Method,ba_device_api:methods()) andalso not maps:is_key(<<"instance">>,R) of
                true -> R;
                false -> fail(2,<<"Use a public Device method from 'beamaudio get methods'; instance credentials are managed by the CLI.">>)
            end;
        _ -> fail(2,<<"Supply a JSON object with a method string.">>)
    catch error:_ -> fail(2,<<"Invalid Device API JSON.">>) end,
    emit(request(Name,Command)).

stop(A,Method) ->
    Timeout=timeout(A),
    Ns=case maps:get(all,A,false) of true -> ba_cli_store:names();false -> names(A) end,
    Results=[try
        request(N,#{<<"method">> => Method}),await_stopped(N,erlang:monotonic_time(millisecond)+Timeout),
        #{device => list_to_binary(N),state => stopped}
    catch throw:{cli_error,_,D} -> #{device => list_to_binary(N),error => D} end || N <- Ns],
    case lists:any(fun(R) -> maps:is_key(error,R) end,Results) of
        true -> fail(1,#{error => incomplete_stop,devices => Results});false -> emit(Results)
    end.
await_stopped(N,Until) ->
    case ba_cli_store:read(N) of
        {error,not_running} -> ok;
        _ -> case erlang:monotonic_time(millisecond)>=Until of
            true -> fail(1,stop_timeout);
            false -> receive after 50 -> ok end,await_stopped(N,Until)
        end
    end.
names(A) ->
    case maps:find(devicename,A) of
        {ok,N} -> Ns=string:split(N,",",all),case Ns=/=[] andalso lists:all(fun ba_cli_store:valid_name/1,Ns) of true -> lists:usort(Ns);false -> fail(2,<<"Use Device names of 1–48 letters/digits, underscore or dash.">>) end;
        error -> fail(2,<<"Supply --devicename.">>)
    end.
one_name(A) -> case names(A) of [N] -> N;_ -> fail(2,<<"This command needs exactly one Device name.">>) end.
capabilities("") -> [];
capabilities(Text) -> lists:usort([case string:trim(K) of
    "speaker" -> <<"speaker">>;"mic" -> <<"microphone">>;"broadcast" -> <<"broadcast">>;
    _ -> fail(2,<<"Capabilities: speaker,mic,broadcast.">>) end || K <- string:split(Text,",",all)]).
timeout(A) ->
    Text=maps:get(timeout,A,"120s"),
    try
        {match,[Digits,Unit]}=re:run(Text,"^([0-9]+)(ms|s)?$",[{capture,all_but_first,list}]),
        N=list_to_integer(Digits)*case Unit of "ms" -> 1;_ -> 1000 end,
        true=N>0 andalso N=<600000,N
    catch _:_ -> fail(2,<<"Timeout must be 1ms–600s, e.g. 120s.">>) end.
scalar(V,#{json := true}) -> emit(V);
scalar(V,_) when is_binary(V) -> io:put_chars([V,$\n]);
scalar(_,_) -> fail(1,<<"No value available.">>).
emit(Value) -> io:put_chars([json:encode(Value),$\n]).
fail(Code,#{error := _}=Detail) -> throw({cli_error,Code,Detail});
fail(Code,R) -> throw({cli_error,Code,#{error => R}}).
