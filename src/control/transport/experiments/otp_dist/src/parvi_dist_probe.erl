%% Local test harness, not a remotely exposed command service or an app runtime.
-module(parvi_dist_probe).
-export([main/0, worker/0, exercise/1, authorize/2, activate/2]).

main() ->
    process_flag(trap_exit, true),
    logger:update_handler_config(default, config, #{type => standard_error}),
    io:setopts(standard_io, [binary, {encoding, utf8}]),
    {ok, _} = application:ensure_all_started(parvi_transport),
    Name = list_to_atom(os:getenv("PARVI_PROBE_NAME")),
    Peer = list_to_atom(os:getenv("PARVI_PROBE_PEER")),
    %% Step 1 explicitly provisions trust locally; step 2 uses the secure default.
    persistent_term:put({?MODULE, peer}, Peer),
    application:set_env(parvi_transport, admission_module, ?MODULE),
    {ok, _} = net_kernel:start(Name, #{name_domain => longnames, net_ticktime => 4}),
    true = erlang:set_cookie(list_to_atom(os:getenv("PARVI_PROBE_COOKIE"))),
    ok = net_kernel:allow([Peer]),
    ok = net_kernel:monitor_nodes(true, #{nodedown_reason => true}),
    Owner = self(),
    spawn_link(fun() -> read_commands(Owner) end),
    emit(#{event => <<"booted">>, node => atom_to_binary(node()), os_pid => list_to_binary(os:getpid()),
        otp => list_to_binary(erlang:system_info(otp_release)),
        erts => list_to_binary(erlang:system_info(version))}),
    loop(#{peer => Peer, channel => undefined, down => false, link => false, node_down => false}).

read_commands(Owner) ->
    case io:get_line(standard_io, "") of
        eof -> Owner ! eof;
        Line -> Owner ! {command, json:decode(Line)}, read_commands(Owner)
    end.
emit(M) -> io:put_chars(standard_io, [json:encode(M), $\n]).
loop(S) ->
    receive
        eof -> halt();
        {command, #{<<"request">> := Ref} = Cmd} ->
            Next = try command(Cmd, S) of
                {Result, State} -> emit(#{request => Ref, result => Result}), State
            catch Class:Reason:Stack ->
                logger:error("Probe command failed: ~p:~p ~p", [Class, Reason, Stack]),
                emit(#{request => Ref, error => iolist_to_binary(io_lib:format("~p:~p", [Class, Reason]))}), S
            end,
            loop(Next);
        {channel, Ctrl, {signal, Signal}} when Ctrl =:= map_get(channel, S) ->
            emit(#{event => <<"signal">>, signal => Signal}), loop(S);
        {channel, Ctrl, ready} when Ctrl =:= map_get(channel, S) ->
            emit(#{event => <<"ready">>}), loop(S);
        {'DOWN', Ref, process, Pid, Reason}
                when Ref =:= map_get(loss_ref, S), Pid =:= map_get(loss_pid, S) ->
            loop(S#{down := true, down_reason => atom_to_binary(Reason)});
        {'EXIT', Pid, Reason} when Pid =:= map_get(loss_pid, S) ->
            loop(S#{link := true, link_reason => atom_to_binary(Reason)});
        {nodedown, Peer, Info} when Peer =:= map_get(peer, S) ->
            loop(S#{node_down := true, node_down_reason => maps:get(nodedown_reason, Info)});
        _ -> loop(S)
    end.

command(#{<<"op">> := <<"start">>, <<"initiator">> := Initiator}, #{peer := Peer} = S) ->
    {ok, Ctrl} = parvi_dist_channel:start_link(self(), Initiator),
    parvi_webrtc_dist:route(Peer, Ctrl),
    {true, S#{channel := Ctrl}};
command(#{<<"op">> := <<"signal">>, <<"signal">> := Signal}, #{channel := Ctrl} = S) ->
    parvi_dist_channel:signal(Ctrl, Signal), {true, S};
command(#{<<"op">> := <<"accept">>}, #{channel := Ctrl} = S) ->
    ok = parvi_webrtc_dist:admit(Ctrl), {true, S};
command(#{<<"op">> := <<"connect">>}, #{peer := Peer} = S) ->
    {net_kernel:connect_node(Peer), S};
command(#{<<"op">> := <<"exercise">>}, #{peer := Peer, channel := Ctrl} = S) ->
    %% Prove ERTS itself owns this WebRTC process as the distribution controller.
    true = lists:member({Peer, Ctrl}, erlang:system_info(dist_ctrl)),
    {exercise(Peer), S};
command(#{<<"op">> := <<"arm_loss">>}, #{peer := Peer} = S) ->
    Pid = spawn_link(Peer, ?MODULE, worker, []),
    Ref = monitor(process, Pid),
    {true, S#{loss_pid => Pid, loss_ref => Ref}};
command(#{<<"op">> := <<"blackhole">>}, #{channel := Ctrl} = S) ->
    ok = gen_server:call(Ctrl, blackhole), {true, S};
command(#{<<"op">> := <<"status">>}, #{peer := Peer, channel := Ctrl} = S) ->
    Channel = case is_pid(Ctrl) andalso is_process_alive(Ctrl) of
        true -> parvi_dist_channel:stats(Ctrl); false -> #{ready => false, native => false}
    end,
    {#{connected => lists:member(Peer, nodes(connected)), channel => Channel,
        down => maps:get(down, S), down_reason => maps:get(down_reason, S, null),
        link => maps:get(link, S), link_reason => maps:get(link_reason, S, null),
        node_down => maps:get(node_down, S), node_down_reason => maps:get(node_down_reason, S, null)}, S}.

exercise(Peer) ->
    Peer = erpc:call(Peer, erlang, node, [], 5000),
    Pid = spawn(Peer, ?MODULE, worker, []),
    Peer = node(Pid), Ref = monitor(process, Pid),
    Token = make_ref(), Data = crypto:strong_rand_bytes(262144),
    Hash = crypto:hash(sha256, Data),
    Pid ! {echo, self(), Token, Data},
    receive {echo, Pid, Token, Data, Hash} -> ok after 10000 -> error(binary_echo_timeout) end,
    [Pid ! {sequence, self(), N} || N <- lists:seq(1, 100)],
    Received = [receive {sequence, Pid, N} -> N after 5000 -> error(sequence_timeout) end
                || _ <- lists:seq(1, 100)],
    Received = lists:seq(1, 100),
    Pid ! {stop, normal},
    receive {'DOWN', Ref, process, Pid, normal} -> ok after 5000 -> error(monitor_timeout) end,
    Linked = spawn_link(Peer, ?MODULE, worker, []),
    Linked ! {stop, probe_link_exit},
    receive {'EXIT', Linked, probe_link_exit} -> ok after 5000 -> error(link_timeout) end,
    #{remote_pid => list_to_binary(pid_to_list(Pid)), remote_node => atom_to_binary(Peer),
      binary_bytes => byte_size(Data), ordered_messages => 100,
      remote_execution => true, monitor => true, link => true}.

worker() ->
    receive
        {echo, From, Ref, Data} ->
            From ! {echo, self(), Ref, Data, crypto:hash(sha256, Data)}, worker();
        {sequence, From, N} -> From ! {sequence, self(), N}, worker();
        {stop, Reason} -> exit(Reason)
    end.

authorize(Ctrl, Expected) ->
    Peer = persistent_term:get({?MODULE, peer}),
    case maps:get(Peer, persistent_term:get(parvi_webrtc_dist, #{}), undefined) =:= Ctrl
            andalso is_process_alive(Ctrl) andalso (Expected =:= any orelse Expected =:= Peer) of
        true -> {ok, Peer}; false -> {error, unauthorized}
    end.
activate(Ctrl, Peer) -> authorize(Ctrl, Peer).
