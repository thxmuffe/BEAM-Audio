%% Persistent native-cluster member with JSON-lines stdin/stdout, logs on stderr.
-module(parvi_inspector).
-export([boot/0, check/0, main/0, request/1]).

%% Platform hosts supply protected identity storage and paths, not cluster policy.
boot() ->
    case check() of
        ok ->
            {ok,_} = application:ensure_all_started(crypto),
            application:load(parvi),
            application:set_env(parvi,native_desk,true),
            {ok,_} = net_kernel:start([parvi_cluster_store:node_name(<<"z_inspector">>),longnames]),
            erlang:set_cookie(binary_to_atom(binary:encode_hex(crypto:strong_rand_bytes(24)))),
            main();
        {error,Reason} ->
            io:format(standard_error,"Inspector transport unavailable: ~p~n",[Reason]),
            init:stop(1)
    end.

%% Used by hosts before creating an identity or attempting admission.
check() ->
    configure_logging(),
    logger:set_primary_config(level,warning),
    case application:ensure_all_started(parvi_transport) of
        {ok,_} -> check_modules(['Elixir.ExDTLS.Native.Nif',
                                'Elixir.ExLibSRTP.Native.Nif','Elixir.ExSCTP',crc_nif]);
        {error,Reason} -> {error,Reason}
    end.
check_modules([]) -> ok;
check_modules([Module|Rest]) ->
    case code:ensure_loaded(Module) of
        {module,Module} -> check_modules(Rest);
        {error,Reason} -> {error,{Module,Reason}}
    end.

main() ->
    configure_logging(),
    io:setopts(standard_io,[binary,{encoding,utf8}]),
    {ok,_} = parvi:start(native_cluster),
    logger:set_primary_config(level,warning),
    await_desk(erlang:monotonic_time(millisecond)+60000),
    Admission = case {os:getenv("PARVI_INSPECTOR_JOIN_FILE"),parvi_cluster_trust:policy()} of
        {false,undefined} -> not_joined;
        {false,_} -> restored;
        {_,Policy} when is_map(Policy) -> restored;
        {Path,_} ->
            {ok,Link} = file:read_file(Path),
            parvi_cluster_desk:join(string:trim(Link))
    end,
    emit(#{event => ready, node => atom_to_binary(node()), admission => Admission,
           desk_connected => maps:get(connected,parvi_relay:status())}),
    loop().

configure_logging() ->
    logger:update_handler_config(default,config,#{type => standard_error}),
    application:load(logger),
    application:set_env(logger,level,warning),
    application:set_env(logger,default_handler,[{config,#{type => standard_error}},{level,warning}]),
    application:set_env(logger,default_formatter,[{colors,[{enabled,false}]}]).

loop() ->
    case io:get_line(standard_io,"") of
        eof -> init:stop();
        {error,_} -> init:stop(1);
        Line -> emit(request(Line)), loop()
    end.

request(Line) ->
    try json:decode(Line) of
        Command when is_map(Command) ->
            Result = command(Command),
            Reply = case Result of
                {ok,Value} -> #{ok => true, result => Value};
                ok -> #{ok => true, result => null};
                {error,Reason} -> #{ok => false, error => Reason}
            end,
            maps:merge(Reply,maps:with([<<"request_id">>],Command))
    catch _:_ -> #{ok => false,error => <<"Invalid JSON request or command failed.">>} end.

command(#{<<"op">> := <<"help">>}) ->
    {ok,#{commands => [status,join,wait,nodes,inspect,clock,capture,sources,refresh_sources,subscribe,play,pause,
                       unsubscribe,sync_delay,minimum_delay,broadcast_start,broadcast_stop]}};
command(#{<<"op">> := <<"join">>, <<"invitation">> := Link}) -> parvi_cluster_desk:join(Link);
command(#{<<"op">> := <<"wait">>} = Command) ->
    Timeout = maps:get(<<"timeout_ms">>,Command,30000),
    case is_integer(Timeout) andalso Timeout >= 0 andalso Timeout =< 60000 of
        true -> await_peer(erlang:monotonic_time(millisecond)+Timeout);
        false -> {error,<<"timeout_ms must be 0-60000.">>}
    end;
command(#{<<"op">> := <<"status">>}) ->
    {ok,#{node => atom_to_binary(node()), desk_connected => maps:get(connected,parvi_relay:status()),
          nodes => parvi_node_api:members(),
          last_rejection => maps:get(last_rejection,parvi_cluster_desk:status(),null),
          connection_event => event_summary(maps:get(event,parvi_cluster_desk:status()))}};
command(Command) -> parvi_node_api:request(Command).

await_desk(Deadline) ->
    case maps:get(connected,parvi_relay:status()) orelse erlang:monotonic_time(millisecond) >= Deadline of
        true -> ok;
        false -> receive after 100 -> await_desk(Deadline) end
    end.

await_peer(Deadline) ->
    ok = net_kernel:monitor_nodes(true),
    try wait_peer(Deadline) after net_kernel:monitor_nodes(false) end.
wait_peer(Deadline) ->
    case nodes() of
        [_|_] -> {ok,#{nodes => parvi_node_api:members()}};
        [] ->
            Left = max(0,Deadline-erlang:monotonic_time(millisecond)),
            receive {nodeup,_} -> wait_peer(Deadline)
            after Left -> {error,<<"No cluster peer connected before timeout.">>} end
    end.

event_summary({channel_stopped,_,{shutdown,Reason}}) when is_atom(Reason) ->
    #{state => channel_stopped,reason => Reason};
event_summary({rejected,Reason}) when is_atom(Reason) -> #{state => rejected,reason => Reason};
event_summary(Event) when is_tuple(Event) -> #{state => element(1,Event)};
event_summary(Event) when is_atom(Event) -> #{state => Event}.

emit(Value) -> io:put_chars(standard_io,[json:encode(json_value(Value)),$\n]).
json_value(M) when is_map(M) -> maps:from_list([{json_value(K),json_value(V)} || {K,V} <- maps:to_list(M)]);
json_value(L) when is_list(L) -> [json_value(V) || V <- L];
json_value(V) when V =:= true; V =:= false; V =:= null -> V;
json_value(V) when is_atom(V) -> atom_to_binary(V);
json_value(V) when is_tuple(V) -> [json_value(E) || E <- tuple_to_list(V)];
json_value(V) -> V.
