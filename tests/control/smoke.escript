#!/usr/bin/env escript
%%! -noshell -start_epmd false -setcookie parvi_smoke_bootstrap
-mode(compile).

main([]) ->
    true = os:putenv("PARVI_RECEPTION_DESK_URL", ""),
    %% Run after compiling src/control/. All sockets stay on loopback.
    Root = filename:dirname(filename:dirname(filename:dirname(filename:absname(escript:script_name())))),
    Ebin = filename:join(Root, "builds/intermediates/control/default/lib/parvi/ebin"),
    true = code:add_patha(Ebin),
    Suffix = integer_to_list(erlang:unique_integer([positive])),
    Name = list_to_atom("parvi_smoke_" ++ Suffix ++ "@127.0.0.1"),
    PeerName = list_to_atom("parvi_peer_" ++ Suffix),
    application:set_env(kernel, inet_dist_use_interface, {127, 0, 0, 1}),
    application:set_env(kernel, erl_epmd_node_listen_port, 0),
    %% peer's standard_io channel avoids EPMD and keeps the test self-contained.
    {ok, _} = net_kernel:start(Name, #{name_domain => longnames}),
    erlang:set_cookie(node(), list_to_atom("parvi_test_" ++ Suffix)),
    {ok, _} = parvi:start(),
    Options = #{name => PeerName, host => "127.0.0.1", longnames => true,
                connection => standard_io,
                args => ["-start_epmd", "false", "-erl_epmd_port", "0", "-pa", Ebin,
                         "-kernel", "inet_dist_use_interface", "{127,0,0,1}",
                         "-setcookie", atom_to_list(erlang:get_cookie())]},
    try
        exercise(Options),
        io:format("PASS: two BEAM nodes, bidirectional chat, restart, leave and rejoin~n")
    after
        application:stop(parvi),
        net_kernel:stop()
    end.

exercise(Options) ->
    {ok, Peer, Remote} = peer:start_link(Options),
    try
        join(Peer, Remote),
        {ok, Out} = parvi:send(<<"Mac A to Mac B">>),
        await(fun() -> lists:member(Out, peer:call(Peer, parvi, history, [])) end),
        {ok, Reply} = peer:call(Peer, parvi, send, [<<"Mac B replies">>]),
        await(fun() -> lists:member(Reply, parvi:history()) end),
        Old = peer:call(Peer, erlang, whereis, [parvi_chat]),
        true = peer:call(Peer, erlang, exit, [Old, kill]),
        await(fun() ->
            New = peer:call(Peer, erlang, whereis, [parvi_chat]),
            is_pid(New) andalso New =/= Old
        end),
        await(fun() -> lists:member(Remote, maps:get(chat_nodes, parvi:status())) end),
        {ok, AfterRestart} = parvi:send(<<"after worker restart">>),
        await(fun() -> lists:member(AfterRestart, peer:call(Peer, parvi, history, [])) end)
    after peer:stop(Peer) end,
    await(fun() -> maps:get(chat_nodes, parvi:status()) =:= [node()] end),
    {ok, Rejoined, Remote} = peer:start_link(Options),
    try
        join(Rejoined, Remote),
        {ok, AfterRejoin} = peer:call(Rejoined, parvi, send, [<<"back again">>]),
        await(fun() -> lists:member(AfterRejoin, parvi:history()) end)
    after peer:stop(Rejoined) end.

join(Peer, Remote) ->
    {ok, _} = peer:call(Peer, parvi, start, []),
    %% Address the known listen port directly: no machine-wide EPMD daemon.
    %% OTP's internal registration query is used only by this test harness.
    {ok, {r4, _, Port}} = peer:call(Peer, gen_server, call, [erl_epmd, client_info_req]),
    ok = application:set_env(kernel, erl_epmd_node_listen_port, Port),
    ok = parvi:connect(Remote),
    await(fun() -> length(maps:get(chat_nodes, parvi:status())) =:= 2 end),
    await(fun() -> length(maps:get(chat_nodes, peer:call(Peer, parvi, status, []))) =:= 2 end).

await(Fun) -> await(Fun, 200).
await(_Fun, 0) -> error(condition_timeout);
await(Fun, Attempts) ->
    case Fun() of
        true -> ok;
        false -> timer:sleep(25), await(Fun, Attempts - 1)
    end.
