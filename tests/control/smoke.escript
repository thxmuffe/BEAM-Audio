#!/usr/bin/env escript
%%! -noshell -start_epmd false -setcookie ba_smoke_bootstrap
-mode(compile).

main([]) ->
    true = os:putenv("BA_RECEPTION_DESK_URL", ""),
    %% Run after compiling src/control/. All sockets stay on loopback.
    Root = filename:dirname(filename:dirname(filename:dirname(filename:absname(escript:script_name())))),
    Ebin = filename:join(Root, "builds/intermediates/control/default/lib/ba_core/ebin"),
    true = code:add_patha(Ebin),
    Suffix = integer_to_list(erlang:unique_integer([positive])),
    Name = list_to_atom("ba_smoke_" ++ Suffix ++ "@127.0.0.1"),
    PeerName = list_to_atom("ba_peer_" ++ Suffix),
    application:set_env(kernel, inet_dist_use_interface, {127, 0, 0, 1}),
    application:set_env(kernel, erl_epmd_node_listen_port, 0),
    %% peer's standard_io channel avoids EPMD and keeps the test self-contained.
    {ok, _} = net_kernel:start(Name, #{name_domain => longnames}),
    erlang:set_cookie(node(), list_to_atom("ba_test_" ++ Suffix)),
    {ok, _} = ba_runtime:start(),
    Options = #{name => PeerName, host => "127.0.0.1", longnames => true,
                connection => standard_io,
                args => ["-start_epmd", "false", "-erl_epmd_port", "0", "-pa", Ebin,
                         "-kernel", "inet_dist_use_interface", "{127,0,0,1}",
                         "-setcookie", atom_to_list(erlang:get_cookie())]},
    try
        exercise(Options),
        io:format("PASS: two BEAM nodes, bidirectional chat, restart, leave and rejoin~n")
    after
        application:stop(ba_core),
        net_kernel:stop()
    end.

exercise(Options) ->
    {ok, Peer, Remote} = peer:start_link(Options),
    try
        join(Peer, Remote),
        {ok, Out} = ba_runtime:send(<<"Mac A to Mac B">>),
        await(fun() -> lists:member(Out, peer:call(Peer, ba_core, history, [])) end),
        {ok, Reply} = peer:call(Peer, ba_core, send, [<<"Mac B replies">>]),
        await(fun() -> lists:member(Reply, ba_runtime:history()) end),
        Old = peer:call(Peer, erlang, whereis, [ba_chat]),
        true = peer:call(Peer, erlang, exit, [Old, kill]),
        await(fun() ->
            New = peer:call(Peer, erlang, whereis, [ba_chat]),
            is_pid(New) andalso New =/= Old
        end),
        await(fun() -> lists:member(Remote, maps:get(chat_nodes, ba_runtime:status())) end),
        {ok, AfterRestart} = ba_runtime:send(<<"after worker restart">>),
        await(fun() -> lists:member(AfterRestart, peer:call(Peer, ba_core, history, [])) end)
    after peer:stop(Peer) end,
    await(fun() -> maps:get(chat_nodes, ba_runtime:status()) =:= [node()] end),
    {ok, Rejoined, Remote} = peer:start_link(Options),
    try
        join(Rejoined, Remote),
        {ok, AfterRejoin} = peer:call(Rejoined, ba_core, send, [<<"back again">>]),
        await(fun() -> lists:member(AfterRejoin, ba_runtime:history()) end)
    after peer:stop(Rejoined) end.

join(Peer, Remote) ->
    {ok, _} = peer:call(Peer, ba_core, start, []),
    %% Address the known listen port directly: no machine-wide EPMD daemon.
    %% OTP's internal registration query is used only by this test harness.
    {ok, {r4, _, Port}} = peer:call(Peer, gen_server, call, [erl_epmd, client_info_req]),
    ok = application:set_env(kernel, erl_epmd_node_listen_port, Port),
    ok = ba_runtime:connect(Remote),
    await(fun() -> length(maps:get(chat_nodes, ba_runtime:status())) =:= 2 end),
    await(fun() -> length(maps:get(chat_nodes, peer:call(Peer, ba_core, status, []))) =:= 2 end).

await(Fun) -> await(Fun, 200).
await(_Fun, 0) -> error(condition_timeout);
await(Fun, Attempts) ->
    case Fun() of
        true -> ok;
        false -> timer:sleep(25), await(Fun, Attempts - 1)
    end.
