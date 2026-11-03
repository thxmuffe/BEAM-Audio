%% Local-only step 2 test driver. Test hooks never arrive over a network endpoint.
-module(parvi_trust_probe).
-export([main/0]).

main() ->
    process_flag(trap_exit, true),
    logger:update_handler_config(default, config, #{type => standard_error}),
    io:setopts(standard_io, [binary, {encoding, utf8}]),
    {ok, _} = application:ensure_all_started(parvi_transport),
    {ok, _} = net_kernel:start(list_to_atom(os:getenv("PARVI_PROBE_NAME")),
                              #{name_domain => longnames, net_ticktime => 12}),
    true = erlang:set_cookie(binary_to_atom(parvi_cluster_auth:fresh(32))),
    {ok, _} = parvi:start(native_cluster),
    ok = parvi:subscribe(),
    {ok, _} = parvi_cluster_trust:start_link(self()),
    Owner = self(), spawn_link(fun() -> read_commands(Owner) end),
    emit(#{event => <<"booted">>, identity => parvi_cluster_trust:identity()}),
    loop(#{}).
read_commands(Owner) ->
    case io:get_line(standard_io, "") of
        eof -> Owner ! eof;
        Line -> Owner ! {command, json:decode(Line)}, read_commands(Owner)
    end.
emit(M) -> io:put_chars(standard_io, [json:encode(M), $\n]).
loop(Connections) ->
    receive
        eof -> halt();
        {command, #{<<"request">> := Ref} = Cmd} ->
            Next = try command(Cmd, Connections) of
                {Result, State} -> emit(#{request => Ref, result => Result}), State
            catch Class:Reason:Stack ->
                logger:error("Trust probe command failed: ~p:~p ~p", [Class, Reason, Stack]),
                emit(#{request => Ref, error => iolist_to_binary(io_lib:format("~p:~p", [Class, Reason]))}), Connections
            end,
            loop(Next);
        {channel, Ctrl, {signal, Signal}} ->
            event(Ctrl, #{event => <<"signal">>, signal => Signal}, Connections), loop(Connections);
        {channel, Ctrl, ready} ->
            event(Ctrl, #{event => <<"ready">>}, Connections), loop(Connections);
        {trust, Ctrl, authorized, Node} ->
            event(Ctrl, #{event => <<"authorized">>, peer => atom_to_binary(Node)}, Connections), loop(Connections);
        {trust, Ctrl, rejected, Reason} ->
            event(Ctrl, #{event => <<"rejected">>, reason => atom_to_binary(Reason)}, Connections), loop(Connections);
        {parvi_message, Message} ->
            emit(#{event => <<"chat">>, message => chat_message(Message)}), loop(Connections);
        _ -> loop(Connections)
    end.
event(Ctrl, Message, Connections) ->
    case [Id || {Id, Pid} <- maps:to_list(Connections), Pid =:= Ctrl] of
        [Id] -> emit(Message#{connection => Id}); _ -> ok
    end.

command(#{<<"op">> := <<"create">>}, C) -> {result(parvi_cluster_trust:create()), C};
command(#{<<"op">> := <<"invite">>} = Cmd, C) ->
    {result(parvi_cluster_trust:invite(maps:get(<<"ttl">>, Cmd, 259200))), C};
command(#{<<"op">> := <<"remove_both">>, <<"target">> := Target}, C) ->
    {result(parvi_cluster_trust:remove_both(Target)), C};
command(#{<<"op">> := <<"retire">>}, C) -> {parvi_cluster_trust:retire(), C};
command(#{<<"op">> := <<"start">>, <<"connection">> := Id, <<"role">> := Role} = Cmd, C) ->
    {ok, Ctrl} = parvi_dist_channel:start_link(self(), Role =:= <<"server">>),
    ok = gen_server:call(Ctrl, observe_auth),
    Attach = case Role of
        <<"server">> -> parvi_cluster_trust:attach(Ctrl, server);
        <<"join">> -> parvi_cluster_trust:attach(Ctrl, {join, maps:get(<<"invitation">>, Cmd)});
        <<"member">> -> parvi_cluster_trust:attach(Ctrl, {member, maps:get(<<"peer">>, Cmd)});
        <<"raw">> -> gen_server:call(Ctrl, hold_auth)
    end,
    case Attach of ok -> {true, C#{Id => Ctrl}}; Error -> gen_server:stop(Ctrl), {result(Error), C} end;
command(#{<<"op">> := <<"signal">>, <<"connection">> := Id, <<"signal">> := Signal}, C) ->
    parvi_dist_channel:signal(maps:get(Id, C), Signal), {true, C};
command(#{<<"op">> := <<"accept">>, <<"connection">> := Id}, C) ->
    {result(parvi_webrtc_dist:admit(maps:get(Id, C))), C};
command(#{<<"op">> := <<"connect">>, <<"peer">> := Name}, C) ->
    {net_kernel:connect_node(binary_to_existing_atom(Name)), C};
command(#{<<"op">> := <<"exercise">>, <<"peer">> := Name}, C) ->
    {parvi_dist_probe:exercise(binary_to_existing_atom(Name)), C};
command(#{<<"op">> := <<"replay">>, <<"from">> := From, <<"to">> := To} = Cmd, C) ->
    Envelope = gen_server:call(maps:get(From, C), last_control),
    NewEnvelope = case maps:get(<<"mode">>, Cmd, <<"binding">>) of
        <<"binding">> -> Envelope;
        <<"nonce">> ->
            {Body, _, _} = parvi_cluster_auth:read(Envelope),
            Channel = sys:get_state(maps:get(To, C)), Trust = sys:get_state(parvi_cluster_trust),
            parvi_cluster_auth:sign(Body#{<<"binding">> := parvi_cluster_auth:binding(maps:get(pc, Channel))},
                                    maps:get(private, Trust));
        Mode when Mode =:= <<"signature">>; Mode =:= <<"name">>; Mode =:= <<"malformed">> ->
            {Body, _, _} = parvi_cluster_auth:read(Envelope),
            Channel = sys:get_state(maps:get(To, C)), Trust = sys:get_state(parvi_cluster_trust),
            Challenge = gen_server:call(maps:get(To, C), last_received),
            {ChallengeBody, _, _} = parvi_cluster_auth:read(Challenge),
            Fresh = Body#{<<"binding">> := parvi_cluster_auth:binding(maps:get(pc, Channel)),
                          <<"server_nonce">> := maps:get(<<"server_nonce">>, ChallengeBody)},
            case Mode of
                <<"signature">> ->
                    Signed = parvi_cluster_auth:sign(Fresh, maps:get(private, Trust)),
                    Signed#{<<"signature">> := binary:copy(<<"0">>, 128)};
                <<"name">> ->
                    Server = maps:get(<<"server">>, ChallengeBody),
                    Members = maps:get(<<"members">>, maps:get(policy, Trust)),
                    Name = maps:get(<<"node">>, maps:get(Server, Members)),
                    parvi_cluster_auth:sign(Fresh#{<<"node">> := Name}, maps:get(private, Trust));
                <<"malformed">> ->
                    parvi_cluster_auth:sign(Fresh#{<<"secret">> := 42}, maps:get(private, Trust))
            end
    end,
    gen_server:cast(maps:get(To, C), {control, NewEnvelope}), {true, C};
command(#{<<"op">> := <<"preauth_native">>, <<"connection">> := Id, <<"peer">> := Name}, C) ->
    Ctrl = maps:get(Id, C), Peer = binary_to_atom(Name),
    parvi_webrtc_dist:route(Peer, Ctrl),
    {#{accepted => parvi_webrtc_dist:admit(Ctrl) =:= ok,
       connected => net_kernel:connect_node(Peer)}, C};
command(#{<<"op">> := <<"preauth_header">>, <<"connection">> := Id}, C) ->
    {gen_server:call(maps:get(Id, C), preauth_header) =:= ok, C};
command(#{<<"op">> := <<"stop_trust">>}, C) ->
    gen_server:stop(parvi_cluster_trust), {true, C};
command(#{<<"op">> := <<"stop_authority">>}, C) ->
    gen_server:stop(parvi_cluster_authority), {true, C};
command(#{<<"op">> := <<"save_cookie">>, <<"peer">> := Name}, C) ->
    put({cookie, Name}, erlang:get_cookie(binary_to_existing_atom(Name))), {true, C};
command(#{<<"op">> := <<"restore_cookie">>, <<"peer">> := Name}, C) ->
    true = erlang:set_cookie(binary_to_existing_atom(Name), get({cookie, Name})), {true, C};
command(#{<<"op">> := <<"chat_send">>, <<"text">> := Text}, C) ->
    {ok, Message} = parvi:send(Text), {chat_message(Message), C};
command(#{<<"op">> := <<"subscribe">>}, C) -> {parvi:subscribe() =:= ok, C};
command(#{<<"op">> := <<"restart_chat">>}, C) -> {restart(parvi_chat), C};
command(#{<<"op">> := <<"restart_pg">>}, C) -> {restart(parvi_pg), C};
command(#{<<"op">> := <<"status">>}, C) ->
    Connections = maps:map(fun(_, Ctrl) ->
        try parvi_dist_channel:stats(Ctrl) catch exit:_ -> #{ready => false, native => false} end
    end, C),
    Policy = case whereis(parvi_cluster_trust) of
        undefined -> null;
        _ -> case parvi_cluster_trust:policy() of undefined -> null; P -> P end
    end,
    {#{policy => Policy,
        connected => [atom_to_binary(N) || N <- nodes(connected)], connections => Connections,
        chat => chat_status(),
        workers => [Id || {Id, _, _, _} <- supervisor:which_children(parvi_sup)],
        legacy_workers => [N || N <- [parvi_swarms, parvi_relay, parvi_direct, parvi_discovery, parvi_network],
                                whereis(N) =/= undefined]}, C}.

chat_message(#{id := Ref, sender := Sender, text := Text, sent_at_ms := Time}) ->
    #{id => list_to_binary(erlang:ref_to_list(Ref)), sender => atom_to_binary(Sender), text => Text, time => Time}.
chat_status() ->
    Status = parvi:status(),
    #{pid => list_to_binary(pid_to_list(whereis(parvi_chat))),
      nodes => [atom_to_binary(N) || N <- maps:get(chat_nodes, Status)],
      process_count => maps:get(chat_process_count, Status),
      subscribers => maps:get(subscriber_count, Status),
      messages => [chat_message(M) || M <- parvi:history()]}.
restart(Name) ->
    Old = whereis(parvi_chat), exit(whereis(Name), kill), await_chat(Old, 100),
    #{old => list_to_binary(pid_to_list(Old)), new => list_to_binary(pid_to_list(whereis(parvi_chat)))}.
await_chat(_, 0) -> error(chat_restart_timeout);
await_chat(Old, Attempts) ->
    case whereis(parvi_chat) of
        New when is_pid(New), New =/= Old -> ok;
        _ -> timer:sleep(10), await_chat(Old, Attempts - 1)
    end.

result({ok, Value}) -> #{ok => Value};
result({error, Reason}) -> #{error => Reason};
result(ok) -> true.
