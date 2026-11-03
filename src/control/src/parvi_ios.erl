%% Runs inside the iPhone BEAM, sharing the actual OTP app and JSON handler.
-module(parvi_ios).
-export([main/0, probe/0, resolve_host/1]).
main() ->
    Root = code:root_dir(),
    code:add_paths(filelib:wildcard(filename:join([Root, "lib", "*", "ebin"]))),
    ok = application:load(parvi),
    %% iOS cannot spawn inet_gethost. Resolve through the statically linked
    %% prim_net NIF, then let Gun look up the original hostname in this VM.
    ok = inet_db:set_lookup([file]),
    application:set_env(parvi, relay_resolver, {?MODULE, resolve_host}),
    application:set_env(parvi, clock_resolver, {?MODULE, resolve_host}),
    case os:getenv("PARVI_AUDIO_PORT") of
        false -> ok;
        _ -> application:set_env(parvi, audio_output_adapter, parvi_ios_audio)
    end,
    CA = filename:join(code:root_dir(), "cacerts.pem"),
    case filelib:is_file(CA) of true -> application:set_env(parvi, relay_cacertfile, CA); false -> ok end,
    case application:get_env(parvi, runtime_profile, legacy_apps) of
        native_cluster ->
            {ok, _} = application:ensure_all_started(crypto),
            Name = parvi_cluster_store:node_name(<<"ios">>),
            {ok, _} = net_kernel:start(Name, #{name_domain => longnames}),
            {ok, _} = application:ensure_all_started(parvi_transport),
            resolve_ice_servers();
        legacy_apps -> ok
    end,
    {ok, _} = application:ensure_all_started(parvi),
    %% The earlier feasibility test is opt-in; normal launch does not kill workers.
    Proof = case os:getenv("PARVI_RUNTIME_PROBE") of
        "1" -> probe();
        _ -> #{status => <<"running">>, otp => list_to_binary(erlang:system_info(otp_release)),
               erts => list_to_binary(erlang:system_info(version)),
               os_pid => list_to_binary(os:getpid()), node => atom_to_binary(node())}
    end,
    case os:getenv("PARVI_PROOF_PATH") of
        false -> ok;
        Path -> ok = file:write_file(Path, json:encode(Proof))
    end,
    Port = list_to_integer(os:getenv("PARVI_BRIDGE_PORT")),
    {ok, Socket} = gen_tcp:connect({127,0,0,1}, Port,
                                  [binary, {packet, line}, {packet_size, 262144}, {active, false}], 10000),
    serve(Socket).

resolve_host(Host) ->
    case net:getaddrinfo(binary_to_list(Host)) of
        {ok, Addresses} ->
            IPv4 = lists:usort([IP || #{family := inet, addr := #{addr := IP}} <- Addresses]),
            IPv6 = lists:usort([IP || #{family := inet6, addr := #{addr := IP}} <- Addresses]),
            case {IPv4, IPv6} of
                {[], []} -> {error, nxdomain};
                _ ->
                    [ok = inet_db:add_host(IP, [binary_to_list(Host)]) || IP <- IPv4 ++ IPv6],
                    {ok, case IPv4 of [] -> inet6; _ -> inet end}
            end;
        Error -> Error
    end.

resolve_ice_servers() ->
    %% ExICE uses inet lookup for STUN/TURN. Seed its configured hostnames using
    %% the same in-process platform resolver as Gun; never spawn inet_gethost.
    Servers = application:get_env(parvi_transport, native_ice_servers,
        [#{urls => application:get_env(parvi, direct_stun_urls, [])}]),
    URLs = lists:append([case maps:get(urls, S, []) of
        U when is_binary(U) -> [U]; Us -> Us end || S <- Servers]),
    lists:foreach(fun(URL) -> case 'Elixir.ExSTUN.URI':parse(URL) of
        {ok, #{host := Host}} -> resolve_host(Host);
        _ -> ok
    end end, URLs),
    ok.

serve(Socket) ->
    case gen_tcp:recv(Socket, 0) of
        {ok, Request} ->
            ok = gen_tcp:send(Socket, [parvi_bridge:request(Request), $\n]),
            serve(Socket);
        {error, _} ->
            %% Do not call init:stop: the VM shares the native app process.
            gen_tcp:close(Socket),
            ok
    end.

%% Initial runtime feasibility check, completed before the UI connects.
%% The test messages pass through the same gen_server used by both apps.
probe() ->
    Before = whereis(parvi_chat),
    {ok, Sent} = parvi:send(<<"On-device runtime self-test">>),
    true = lists:member(Sent, parvi:history()),
    Ref = monitor(process, Before),
    exit(Before, kill),
    receive {'DOWN', Ref, process, Before, _} -> ok after 2000 -> error(worker_did_not_stop) end,
    After = await_worker(Before, 100),
    %% Independent clock diagnostics may already have arrived after restart.
    false = lists:member(Sent, parvi:history()),
    {ok, _} = parvi:send(<<"On-device Erlang self-test passed.">>),
    case application:get_env(parvi, runtime_profile, legacy_apps) of
        native_cluster -> ok;
        legacy_apps ->
            [#{id := SwarmId} | _] = parvi_swarms:snapshot(),
            case parvi_relay:enabled() of
                false -> ok = parvi_swarms:send(SwarmId, <<"On-device Erlang self-test passed.">>);
                true -> ok
            end
    end,
    #{status => <<"passed">>, otp => list_to_binary(erlang:system_info(otp_release)),
      erts => list_to_binary(erlang:system_info(version)),
      os_pid => list_to_binary(os:getpid()),
      worker_before => list_to_binary(pid_to_list(Before)),
      worker_after => list_to_binary(pid_to_list(After)),
      message_verified => true, supervisor_restart_verified => true}.

await_worker(_Before, 0) -> error(worker_restart_timeout);
await_worker(Before, Attempts) ->
    Ready = case application:get_env(parvi, runtime_profile, legacy_apps) of
        native_cluster -> is_pid(whereis(parvi_cluster_desk));
        legacy_apps -> is_pid(whereis(parvi_discovery)) andalso is_pid(whereis(parvi_swarms))
    end,
    case whereis(parvi_chat) of
        Pid when is_pid(Pid), Pid =/= Before, Ready -> Pid;
        _ -> timer:sleep(20), await_worker(Before, Attempts - 1)
    end.
