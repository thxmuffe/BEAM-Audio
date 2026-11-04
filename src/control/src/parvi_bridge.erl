%% Shared JSON interface for native hosts. request/1 is transport-independent.
%% macOS main/0 uses app-owned stdin/stdout pipes, never a network listener.
-module(parvi_bridge).
-export([main/0, request/1]).

main() ->
    logger:update_handler_config(default, config, #{type => standard_error}),
    io:setopts(standard_io, [binary, {encoding, utf8}]),
    {ok, _} = parvi:start(),
    loop().

loop() ->
    case io:get_line(standard_io, "") of
        eof -> init:stop();
        {error, _} -> init:stop(1);
        Line ->
            io:put_chars(standard_io, [request(Line), $\n]),
            loop()
    end.

%% An embedded host can call this same function without emulating terminal I/O.
request(JSON) ->
    case application:get_env(parvi, runtime_profile, legacy_apps) of
        native_cluster -> parvi_native_bridge:request(JSON);
        legacy_apps -> legacy_request(JSON)
    end.

legacy_request(JSON) ->
    Reply = try
        Request = json:decode(JSON),
        Result = command(Request),
        Response = case Result of
            {ok, Data} -> (snapshot())#{<<"error">> => null, <<"result">> => Data};
            _ -> (snapshot())#{<<"error">> => Result}
        end,
        maps:merge(Response, maps:with([<<"request_id">>], Request))
    catch
        _:_ -> (snapshot())#{<<"error">> => <<"Invalid request or unavailable worker. Try again.">>}
    end,
    iolist_to_binary(json:encode(Reply)).

command(#{<<"method">> := <<"snapshot">>}) -> null;
command(#{<<"method">> := <<"configure_desk">>, <<"url">> := URL}) ->
    case parvi_relay:valid_url(URL) of
        true ->
            ok = application:stop(parvi),
            ok = application:set_env(parvi, reception_desk_url, URL),
            {ok, _} = parvi:start(), null;
        false -> <<"Use wss://your-desk/relay/v1 (ws:// is allowed only on localhost).">>
    end;
command(#{<<"method">> := <<"create_swarm">>} = Request) ->
    swarm_result(parvi_swarms:create(maps:get(<<"name">>, Request, <<>>)));
command(#{<<"method">> := <<"join_swarm">>, <<"invitation">> := Invitation}) ->
    case parvi_invitation:parse(Invitation) of
        {ok, #{desk := Desk} = Parsed} ->
            case parvi_relay:url() of
                Desk -> swarm_result(parvi_swarms:join_relay(Parsed));
                _ -> <<"Set this invitation's Reception desk URL first. Changing desks starts a new node session.">>
            end;
        {ok, #{node := Name, cookie := Cookie, swarm := Id, token := Token}} ->
            case command(#{<<"method">> => <<"connect">>, <<"node">> => Name, <<"cookie">> => Cookie}) of
                null -> swarm_result(parvi_swarms:join(binary_to_existing_atom(Name), Id, Token));
                Error -> Error
            end;
        _ -> <<"Invalid cluster invitation. Copy a fresh invitation from a cluster member.">>
    end;
command(#{<<"method">> := <<"send_swarm">>, <<"swarm_id">> := Id, <<"text">> := Text}) ->
    swarm_result(parvi_swarms:send(Id, Text));
command(#{<<"method">> := <<"leave_swarm">>, <<"swarm_id">> := Id}) ->
    swarm_result(parvi_swarms:leave(Id));
command(#{<<"method">> := <<"remove_both">>, <<"swarm_id">> := Id, <<"target">> := Target}) ->
    swarm_result(parvi_swarms:remove_both(Id, Target));
command(#{<<"method">> := <<"discover">>, <<"url">> := URL}) ->
    case parvi_discovery:discover(URL) of
        ok -> null;
        {error, Error} -> Error
    end;
command(#{<<"method">> := <<"send">>, <<"text">> := Text}) ->
    case parvi:send(Text) of
        {ok, _} -> null;
        {error, _} -> <<"Use 1–4096 bytes of UTF-8 text.">>
    end;
command(#{<<"method">> := <<"connect">>, <<"connection_string">> := String}) ->
    case parvi_connection:parse(String) of
        {ok, #{node := Name, cookie := Cookie}} ->
            command(#{<<"method">> => <<"connect">>, <<"node">> => Name, <<"cookie">> => Cookie});
        {error, _} -> <<"Invalid connection string. Copy a fresh one from the other instance.">>
    end;
command(#{<<"method">> := <<"connect">>, <<"node">> := Name, <<"cookie">> := Cookie})
        when is_binary(Name), byte_size(Name) > 0, byte_size(Name) =< 128,
             is_binary(Cookie), byte_size(Cookie) > 0, byte_size(Cookie) =< 128 ->
    %% Developer-only loopback prototype. Bound the names accepted by the UI.
    case re:run(Name, <<"^parvi_(mac|windows)_[0-9]+@127\\.0\\.0\\.1$">>, [{capture, none}]) of
        match ->
            Node = binary_to_atom(Name, utf8),
            erlang:set_cookie(Node, binary_to_atom(Cookie, utf8)),
            case parvi:connect(Node) of
                ok -> null;
                _ -> <<"Could not connect. Check the node name and shared cookie.">>
            end;
        _ -> <<"This build connects to OpenSound app instances on this computer only.">>
    end;
command(_) -> <<"Unsupported request.">>.

snapshot() ->
    Status = parvi:status(),
    #{<<"node">> => case parvi_relay:id() of N when is_atom(N) -> atom_to_binary(N); N -> N end,
      <<"relay">> => parvi_relay:status(),
      <<"direct">> => parvi_direct:snapshot(),
      <<"connection_string">> => case {parvi_relay:enabled(), node()} of
          {true, _} -> null;
          {_, nonode@nohost} -> null;
          _ -> parvi_connection:local()
      end,
      <<"network">> => parvi_network:snapshot(),
      <<"swarms">> => parvi_swarms:snapshot(),
      <<"runtime_info">> => iolist_to_binary(io_lib:format("OTP ~s / ERTS ~s / worker ~p",
          [erlang:system_info(otp_release), erlang:system_info(version), whereis(parvi_chat)])),
      <<"known_nodes">> => parvi_discovery:nodes(),
      <<"peers">> => [atom_to_binary(N) || N <- maps:get(chat_nodes, Status), N =/= node()],
      <<"messages">> => [message(M) || M <- parvi:history()]}.

swarm_result({ok, Id}) -> {ok, #{swarm_id => Id}};
swarm_result(ok) -> null;
swarm_result({error, Error}) -> Error.

message(#{id := Id, text := Text, sender := Sender, sent_at_ms := Time} = M) ->
    #{<<"id">> => list_to_binary(erlang:ref_to_list(Id)), <<"text">> => Text,
      <<"sender">> => atom_to_binary(Sender), <<"time">> => Time,
      <<"kind">> => atom_to_binary(maps:get(kind, M, user)),
      <<"event">> => atom_to_binary(maps:get(event, M, none)),
      <<"level">> => case maps:find(level, M) of {ok, L} -> atom_to_binary(L); error -> null end}.
