%% Runs inside the iPhone BEAM, sharing the actual OTP app and JSON handler.
-module(ba_ios).
-export([main/0, resolve_host/1]).
main() ->
    Root = code:root_dir(),
    code:add_paths(filelib:wildcard(filename:join([Root, "lib", "*", "ebin"]))),
    ok = application:load(ba_core),
    %% iOS cannot spawn inet_gethost. Resolve through the statically linked
    %% prim_net NIF, then let Gun look up the original hostname in this VM.
    ok = inet_db:set_lookup([file]),
    application:set_env(ba_core, relay_resolver, {?MODULE, resolve_host}),
    application:set_env(ba_core, clock_resolver, {?MODULE, resolve_host}),
    case os:getenv("BA_AUDIO_PORT") of
        false -> ok;
        _ -> application:set_env(ba_core, audio_output_adapter, ba_ios_audio)
    end,
    CA = filename:join(code:root_dir(), "cacerts.pem"),
    case filelib:is_file(CA) of true -> application:set_env(ba_core, relay_cacertfile, CA); false -> ok end,
    %% The embedded app is always an unnamed, scoped Swarm Device.
    {ok,swarm_control} = application:get_env(ba_core,runtime_profile),
    {ok, _} = application:ensure_all_started(crypto),
    resolve_ice_servers(),
    ba_app_session:configure(),
    {ok, _} = application:ensure_all_started(ba_core),
    Proof = #{status => <<"running">>, otp => list_to_binary(erlang:system_info(otp_release)),
              erts => list_to_binary(erlang:system_info(version)),
              os_pid => list_to_binary(os:getpid()), node => atom_to_binary(node())},
    case os:getenv("BA_PROOF_PATH") of
        false -> ok;
        Path -> ok = file:write_file(Path, json:encode(Proof))
    end,
    Port = list_to_integer(os:getenv("BA_BRIDGE_PORT")),
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
    Servers = application:get_env(ba_transport, native_ice_servers,
        [#{urls => application:get_env(ba_core, direct_stun_urls, [])}]),
    application:set_env(ba_transport,native_ice_servers,Servers),
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
            ok = gen_tcp:send(Socket, [ba_bridge:request(Request), $\n]),
            serve(Socket);
        {error, _} ->
            %% Do not call init:stop: the VM shares the native app process.
            gen_tcp:close(Socket),
            ba_swarm:leave(),
            ok
    end.
