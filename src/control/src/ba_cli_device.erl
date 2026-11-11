%% One independent unnamed Device. The local owner-only socket exposes the same
%% allowlisted API as app pipes; it never accepts Erlang expressions or RPC.
-module(ba_cli_device).
-behaviour(gen_server).
-export([boot/0,start_link/1,call/2]).
-export([init/1,handle_call/3,handle_cast/2,handle_info/2,terminate/2,format_status/1]).
boot() ->
    [Dir,Instance,Root]=init:get_plain_arguments(),
    Log=filename:join(Dir,"runtime.log"),
    logger:remove_handler(default),
    ok=logger:add_handler(default,logger_std_h,#{config => #{type => file,file => Log}}),
    try
        nonode@nohost=node(),
        Launch=filename:join(Dir,"launch.json"),{ok,B}=file:read_file(Launch),C=json:decode(B),
        true=list_to_binary(Instance)=:=maps:get(<<"instance">>,C),ok=ba_cli_store:remove(Launch),
        {ok,_}=application:ensure_all_started(crypto),
        Seed=ba_cli_store:identity(Dir),os:putenv("BA_IDENTITY_SEED",binary_to_list(Seed)),os:putenv("BA_STATE_DIR",Dir),
        os:putenv("BA_APP_PID",os:getpid()),
        os:putenv("BA_DEVICE_NAME",case maps:get(<<"observer">>,C,false) of
            true -> "Swarm monitor";false -> binary_to_list(maps:get(<<"name">>,C)) end),
        os:putenv("BA_MAC_AUDIO_HELPER",filename:join([Root,"builds/CLI","ba_audio_input"])),
        os:putenv("BA_MAC_DEVICE_AUDIO_HELPER",filename:join([Root,"builds/CLI","ba_device_audio"])),
        ok=application:load(ba_core),
        Consent=#{speaker => false,microphone => false,broadcast => false},
        ok=ba_app_session:configure(#{platform => mac,consent => Consent}),
        case maps:get(<<"observer">>,C,false) of
            true -> application:set_env(ba_core,audio_automation,false),application:set_env(ba_core,swarm_observer,true);
            false -> ok
        end,
        {ok,_}=ba_runtime:start(swarm_control),
        case maps:find(<<"web">>,C) of
            {ok,#{<<"assets">> := Assets,<<"port">> := WebPort}} ->
                application:set_env(ba_device_web,options,#{assets => binary_to_list(Assets),port => WebPort}),
                {ok,_}=application:ensure_all_started(ba_device_web);
            error -> ok
        end,
        case maps:get(<<"enabled">>,C) of
            null -> ok;
            Enabled -> ok=ba_device_config:change(maps:from_list([{K,lists:member(atom_to_binary(K),Enabled)} || K <- [speaker,microphone,broadcast]]),#{})
        end,
        Public=maps:without([<<"invitation">>],C),
        {ok,Pid}=supervisor:start_child(ba_sup,#{id => ?MODULE,start => {?MODULE,start_link,[Public#{dir => Dir}]},restart => temporary}),
        Command=case maps:get(<<"mode">>,C) of
            <<"idle">> -> #{<<"method">> => <<"snapshot">>};
            <<"create">> -> #{<<"method">> => <<"create_swarm">>,<<"name">> => maps:get(<<"name">>,C),<<"desks">> => [maps:get(<<"desk">>,C)]};
            <<"join">> -> #{<<"method">> => <<"join_swarm">>,<<"invitation">> => maps:get(<<"invitation">>,C)}
        end,
        Pid ! {start_swarm,Command},
        receive shutdown -> ok end
    catch Class:Reason:Stack ->
        %% Do not print launch arguments, credentials or private key material.
        Trace=[{M,F,A,proplists:get_value(line,Info)} || {M,F,A,Info} <- Stack,is_integer(A)],
        logger:error("CLI startup failed: ~p ~p ~p",[Class,safe_reason(Reason),Trace]),
        ba_cli_store:remove(filename:join(Dir,"running.json")),init:stop(1)
    end.
safe_reason({badmatch,{error,R}}) when is_atom(R) -> {badmatch,R};
safe_reason(R) when is_atom(R) -> R;
safe_reason(_) -> startup_failed.
start_link(C) -> gen_server:start_link({local,?MODULE},?MODULE,C,[]).
init(#{<<"socket">> := Path}=C) ->
    process_flag(trap_exit,true),
    {ok,L}=gen_tcp:listen(0,[local,binary,{ifaddr,{local,Path}},{packet,line},{packet_size,262144},{active,false},{send_timeout,2000},{send_timeout_close,true}]),
    ok=file:change_mode(Path,8#600),Parent=self(),
    A=spawn_link(fun() -> accept(L,Parent) end),
    {ok,C#{listener => L,acceptor => A,startup_error => null}}.
accept(L,Parent) ->
    case gen_tcp:accept(L) of
        {ok,S} ->
            %% One bounded request per connection, keeping framing identical to apps.
            case gen_tcp:recv(S,0,5000) of
                {ok,B} ->
                    try
                        Request=json:decode(B),
                        Reply=gen_server:call(Parent,{request,Request},20000),
                        ok=gen_tcp:send(S,[json:encode(Reply),$\n]),
                        case {maps:get(<<"method">>,Request,<<>>),maps:get(error,Reply,invalid)} of
                            {<<"stop">>,null} -> gen_server:cast(Parent,stop);
                            {<<"kill">>,null} -> gen_server:cast(Parent,kill);
                            _ -> ok
                        end
                    catch _:_ -> gen_tcp:send(S,[json:encode(#{error => <<"Local request failed.">>}),$\n]) end;
                _ -> ok
            end,
            gen_tcp:close(S),accept(L,Parent);
        {error,closed} -> ok;
        {error,R} -> exit({accept_failed,R})
    end.
handle_info({start_swarm,Command},C) ->
    Reply=ba_device_api:request(Command),
    {noreply,C#{startup_error := maps:get(<<"error">>,Reply,null)}};
handle_info({'EXIT',A,R},#{acceptor := A}=S) -> {stop,{acceptor_exit,R},S};
handle_info(_,S) -> {noreply,S}.
handle_call({request,#{<<"instance">> := I}=R},_,#{<<"instance">> := I}=S) ->
    Method=maps:get(<<"method">>,R,<<"snapshot">>),
    Reply=case Method of
        <<"stop">> -> #{error => null};
        <<"kill">> -> #{error => null};
        _ -> ba_device_api:request(maps:remove(<<"instance">>,R))
    end,
    %% The optional service publishes its endpoint; native core releases must
    %% not import modules from a web application they do not package.
    WebURL=case whereis(ba_device_web_sup) of
        undefined -> null;
        _ -> application:get_env(ba_device_web,origin,null)
    end,
    Meta=#{observer => maps:get(<<"observer">>,S,false),name => maps:get(<<"name">>,S),instance => I,os_pid => list_to_binary(os:getpid()),node => atom_to_binary(node()),startup_error => maps:get(startup_error,S),web_url => WebURL},
    {reply,Reply#{managed => Meta},S};
handle_call(_,_,S) -> {reply,#{error => <<"Device instance mismatch.">>},S}.
handle_cast(stop,S) ->
    ba_swarm:disconnect(),init:stop(),{stop,normal,S};
handle_cast(kill,S) ->
    %% Only this process can be killed, after an instance-checked local command.
    spawn(fun() -> os:cmd("/bin/kill -KILL "++os:getpid()) end),{stop,normal,S};
handle_cast(_,S) -> {noreply,S}.
terminate(_,S) ->
    gen_tcp:close(maps:get(listener,S)),ba_cli_store:remove(maps:get(<<"socket">>,S)),
    ba_cli_store:remove(filename:join(maps:get(dir,S),"running.json")),ok.
format_status(Status) -> maps:map(fun(state,S) -> maps:with([<<"name">>,startup_error],S);(log,_) -> [];(_,_) -> redacted end,Status).
call(Record,Request) ->
    case gen_tcp:connect({local,maps:get(<<"socket">>,Record)},0,[local,binary,{packet,line},{packet_size,2000000},{active,false}],1000) of
        {ok,S} ->
            try
                ok=gen_tcp:send(S,[json:encode(Request#{<<"instance">> => maps:get(<<"instance">>,Record)}),$\n]),
                case gen_tcp:recv(S,0,20000) of {ok,B} -> {ok,json:decode(B)};E -> E end
            after gen_tcp:close(S) end;
        E -> E
    end.
