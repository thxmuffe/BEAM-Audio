%% CLI presentation/lifecycle only. Device behavior and readiness live in OTP APIs.
-module(ba_cli).
-export([main/2,spec/1,new_device/2,request/2,wait/3,timeout/1]).
main(Args,Root) ->
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
          #{name => once,long => "-once",action => {store,true},default => false},
          #{name => interval,long => "-interval",type => {integer,[{min,500},{max,10000}]},default => 1000}],
          handler => fun(A) -> ba_cli_monitor:run(A,Root) end},
      "new" => #{commands => #{"device" => Device(fun(A) -> emit(new_device(A,Root)) end,
          [#{name => createswarm,long => "-createswarm",action => {store,true},default => false},
           #{name => joinswarm,long => "-joinswarm",type => string},
           #{name => enable,long => "-enable",type => string},
           #{name => desk,long => "-desk",type => string},
           #{name => until,long => "-wait",type => {string,["endpoint","admitted","ready"]},default => "admitted"},
           #{name => web_assets,long => "-web-assets",type => string},
           #{name => web_port,long => "-web-port",type => {integer,[{min,0},{max,65535}]},default => 8766}])}},
      "inspect" => #{commands => #{
          "device" => Device(fun(A) ->
              Command=case maps:find(deviceid,A) of
                  error -> #{<<"method">> => <<"snapshot">>};
                  {ok,Id} -> #{<<"method">> => <<"inspect">>,<<"device">> => list_to_binary(Id)}
              end,
              emit(request(one_name(A),Command))
          end,[#{name => deviceid,long => "-deviceid",type => string}]),
          "swarm" => Device(fun inspect_swarm/1,[#{name => swarmid,long => "-swarmid",type => string,required => true}]),
          "legacy" => #{handler => fun(_) -> fail(2,<<"Use src/Tools/Inspector/run.sh; the legacy Inspector is unchanged and is not a scoped Swarm client.">>) end}}},
      "get" => #{commands => #{
          "web" => Device(fun(A) ->
              R=request(one_name(A),#{<<"method">> => <<"snapshot">>}),
              case maps:get(<<"web_url">>,maps:get(<<"managed">>,R),null) of
                  null -> fail(1,<<"This Device has no web service. Start it with --web-assets DIR.">>);
                  URL -> scalar(URL,A)
              end
          end,[]),
          "swarm" => Device(fun(A) -> scalar(get_swarm(A),A) end,[]),
          "invitation" => Device(fun(A) -> R=request(one_name(A),#{<<"method">> => <<"invitation">>}),scalar(maps:get(<<"result">>,R),A) end,[])}},
      "history" => #{commands => #{"device" => Device(fun(A) -> emit(request(one_name(A),#{<<"method">> => <<"configuration">>})) end,[])}},
      "undo" => #{commands => #{"device" => Device(fun(A) -> history_action(A,<<"undo">>) end,[])}},
      "redo" => #{commands => #{"device" => Device(fun(A) -> history_action(A,<<"redo">>) end,[])}},
      "set" => #{commands => #{"device" => Device(fun set_device/1,
          [#{name => enable,long => "-enable",type => string,default => ""},#{name => disable,long => "-disable",type => string,default => ""}])}},
      "wait" => #{commands => #{"device" => Device(fun(A) -> emit(wait(names(A),maps:get(until,A),timeout(A))) end,
          [#{name => until,long => "-until",type => {string,["endpoint","admitted","ready","audio-flowing"]},default => "ready"}])}},
      "stop" => #{commands => #{"device" => Device(fun(A) -> stop(A,<<"stop">>) end,[#{name => all,long => "-all",action => {store,true},default => false}])}},
      "kill" => #{commands => #{"device" => Device(fun(A) -> stop(A,<<"kill">>) end,[#{name => all,long => "-all",action => {store,true},default => false}])}}
    }}.
new_device(A,Root) ->
    Name=one_name(A),Enabled=capabilities(maps:get(enable,A,"")),Timeout=timeout(A),
    Create=maps:get(createswarm,A),Join=maps:get(joinswarm,A,undefined),
    case Create andalso Join=/=undefined of true -> fail(2,<<"Choose createswarm or joinswarm, not both.">>);false -> ok end,
    case os:type() of {unix,darwin} -> ok;_ -> fail(2,<<"Real hardware CLI currently supports macOS only.">>) end,
    Helpers=[{<<"speaker">>,"ba_device_audio"},{<<"microphone">>,"ba_audio_input"},{<<"broadcast">>,"ba_audio_input"}],
    [case filelib:is_regular(filename:join([Root,"builds/CLI",H])) of true -> ok;false -> fail(2,<<"Missing native binding; run bash src/Tools/CLI/build.sh.">>) end || {K,H} <- Helpers,lists:member(K,Enabled)],
    D=ba_cli_store:dir(Name),ok=ba_cli_store:private_dir(ba_cli_store:home()),ok=ba_cli_store:private_dir(D),
    Instance=binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(16))),
    Socket=filename:join("/tmp","ba-device-"++Instance++".sock"),
    Mode=case {Create,Join} of {true,_} -> <<"create">>;{_,undefined} -> <<"idle">>;_ -> <<"join">> end,
    Desk=maps:get(desk,A,"wss://parvi-reception-desk.onrender.com/relay/v1"),
    C0=#{instance => list_to_binary(Instance),name => list_to_binary(Name),socket => list_to_binary(Socket),mode => Mode,enabled => case maps:is_key(enable,A) of true -> Enabled;false -> null end,desk => list_to_binary(Desk),
        observer => maps:get(observer,A,false),invitation => case Join of undefined -> null;_ -> list_to_binary(Join) end},
    C=case maps:find(web_assets,A) of
        error -> C0;
        {ok,Assets} ->
            case filelib:is_dir(Assets) andalso filelib:is_regular(filename:join([Root,
                    "builds/intermediates/DeviceWeb/default/lib/ba_device_web/ebin/ba_device_web.app"])) of
                true -> C0#{web => #{assets => list_to_binary(filename:absname(Assets)),port => maps:get(web_port,A,8766)}};
                false -> fail(2,<<"Check --web-assets and build the service: bash src/Services/DeviceWeb/build.sh.">>)
            end
    end,
    Record=filename:join(D,"running.json"),
    case file:open(Record,[write,binary,exclusive]) of
        {ok,F} -> ok=file:change_mode(Record,8#600),ok=file:write(F,json:encode(maps:with([instance,name,socket],C))),file:close(F);
        {error,eexist} -> fail(1,#{error => <<"Device is already running, starting, or has a stale process record. Inspect/stop it before retrying.">>,device => Name});
        {error,R} -> fail(1,R)
    end,
    try
        ok=ba_cli_store:write(filename:join(D,"launch.json"),C),
        Erl=os:find_executable("erl"),
        Paths=filelib:wildcard(filename:join([Root,"builds/intermediates/control/default/lib","*","ebin"]))++
              filelib:wildcard(filename:join([Root,"builds/CLI/runtime/native_lib","*","ebin"]))++
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
inspect_swarm(A) ->
    Id=list_to_binary(maps:get(swarmid,A)),
    Candidates=case maps:find(devicename,A) of {ok,_} -> names(A);error -> ba_cli_store:names() end,
    Views=[R || N <- Candidates,R <- [request(N,#{<<"method">> => <<"snapshot">>})],maps:get(<<"swarm">>,maps:get(<<"swarm">>,R,#{}),null)=:=Id],
    case Views of [] -> fail(1,<<"No running authorized local view of that Swarm. Supply --devicename when needed.">>);_ -> emit(#{swarm => Id,views => Views}) end.
get_swarm(A) ->
    R=request(one_name(A),#{<<"method">> => <<"snapshot">>}),
    case maps:get(<<"swarm">>,maps:get(<<"swarm">>,R),null) of null -> fail(1,<<"Device has no active Swarm.">>);Id -> Id end.
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
