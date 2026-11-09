%% Historical trusted-app/Distributed Erlang path; not the secure Swarm API.
%% Shared JSON interface for native hosts. request/1 is transport-independent.
%% macOS main/0 uses app-owned stdin/stdout pipes, never a network listener.
-module(ba_bridge).
-export([main/0, request/1]).

main() ->
    logger:update_handler_config(default, config, #{type => standard_error}),
    io:setopts(standard_io, [binary, {encoding, utf8}]),
    ba_app_session:configure(),
    {ok, _} = ba_runtime:start(),
    loop().

loop() ->
    case io:get_line(standard_io, "") of
        eof -> close_swarm(),init:stop();
        {error, _} -> init:stop(1);
        Line ->
            io:put_chars(standard_io, [request(Line), $\n]),
            loop()
    end.

%% An embedded host can call this same function without emulating terminal I/O.
request(JSON) ->
    Bin = if is_binary(JSON) -> JSON; true -> iolist_to_binary(JSON) end,
    case application:get_env(ba_core, runtime_profile, legacy_apps) of
        swarm_control -> swarm_request(Bin);
        native_cluster -> ba_native_bridge:request(Bin);
        legacy_apps -> legacy_request(Bin)
    end.

swarm_request(JSON) ->
    Reply = try
        Request = json:decode(JSON),
        Result = swarm_command(Request),
        Response = case Result of
            {ok, Data} -> (swarm_snapshot())#{<<"error">> => null, <<"result">> => Data};
            ok -> (swarm_snapshot())#{<<"error">> => null};
            null -> (swarm_snapshot())#{<<"error">> => null};
            {error, Reason} -> (swarm_snapshot())#{<<"error">> => format_error(Reason)};
            _ -> (swarm_snapshot())#{<<"error">> => Result}
        end,
        maps:merge(Response, maps:with([<<"request_id">>], Request))
    catch
        _:_ -> (swarm_snapshot())#{<<"error">> => <<"Invalid request or unavailable worker.">>}
    end,
    iolist_to_binary(json:encode(Reply)).

swarm_command(#{<<"method">> := <<"capability">>,<<"capability">> := K,<<"enabled">> := B}) ->
    Key=case K of <<"speaker">> -> speaker;<<"microphone">> -> microphone;<<"broadcast">> -> broadcast end,
    ba_app_session:capability(Key,B);
swarm_command(#{<<"method">> := <<"exclude">>,<<"device">> := Id,<<"excluded">> := B}) -> ba_app_session:exclude(Id,B);
swarm_command(#{<<"method">> := <<"send">>,<<"text">> := Text}) -> ba_swarm_chat:send(Text);
swarm_command(#{<<"method">> := <<"offset">>,<<"offset_ms">> := Offset}) -> ba_swarm_clock:set_offset(Offset);
swarm_command(#{<<"method">> := <<"inspect">>,<<"device">> := Device}) ->
    {Pub,_}=ba_device_store:identity(),
    case Device=:=binary:encode_hex(Pub) of true -> {ok,ba_device_handler:capabilities()};false -> ba_swarm_control:read_capabilities(Device) end;
swarm_command(#{<<"method">> := <<"invitation">>}) -> ba_swarm_membership:invite(3600);
swarm_command(#{<<"method">> := <<"snapshot">>}) -> null;
swarm_command(#{<<"method">> := <<"list_contacts">>}) ->
    {ok, ba_contacts:list()};
swarm_command(#{<<"method">> := <<"save_contact">>,<<"value">> := Value,<<"name">> := Name}) ->
    case ba_swarm_job:hex(Value,64) of
        true -> ba_contacts:put(Value,Name);
        false -> {_,I}=ba_swarm_passport:parse_invitation(Value),ba_contacts:put(maps:get(<<"authority">>,I),Name)
    end;
swarm_command(#{<<"method">> := <<"contact_from_invitation">>,<<"invitation">> := Link,<<"name">> := Name}) ->
    {_,I}=ba_swarm_passport:parse_invitation(Link),ba_contacts:put(maps:get(<<"authority">>,I),Name);
swarm_command(#{<<"method">> := <<"put_contact">>, <<"id">> := Id, <<"name">> := Name}) ->
    ba_contacts:put(Id, Name);
swarm_command(#{<<"method">> := <<"delete_contact">>, <<"id">> := Id}) ->
    ba_contacts:delete(Id);
swarm_command(#{<<"method">> := <<"put_group">>, <<"name">> := Name, <<"ids">> := Ids}) ->
    ba_contacts:group(Name, Ids);
swarm_command(#{<<"method">> := <<"delete_group">>, <<"name">> := Name}) ->
    ba_contacts:delete_group(Name);
swarm_command(#{<<"method">> := <<"create_swarm">>, <<"name">> := Name, <<"desks">> := Desks}) ->
    ba_swarm:create(Name, Desks);
swarm_command(#{<<"method">> := <<"join_swarm">>, <<"invitation">> := Link}) ->
    ba_swarm:join(Link);
swarm_command(#{<<"method">> := <<"invite">>, <<"selection">> := Sel} = Req) ->
    TTL = maps:get(<<"ttl">>, Req, 3600),
    Selection = case Sel of
        #{<<"group">> := G} -> {group, G};
        Ids when is_list(Ids) -> Ids
    end,
    ba_swarm:invite(Selection, TTL);
swarm_command(#{<<"method">> := <<"leave_swarm">>}) ->
    ba_swarm:leave();
swarm_command(#{<<"method">> := <<"end_swarm">>}) ->
    ba_swarm:end_swarm();
swarm_command(_) ->
    {error, <<"Unsupported request.">>}.

swarm_snapshot() -> ba_app_session:snapshot().

format_error(Reason) when is_binary(Reason) -> Reason;
format_error(Reason) when is_atom(Reason) -> atom_to_binary(Reason);
format_error(Reason) -> iolist_to_binary(io_lib:format("~p", [Reason])).

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
    case ba_relay:valid_url(URL) of
        true ->
            ok = application:stop(ba_core),
            ok = application:set_env(ba_core, reception_desk_url, URL),
            {ok, _} = ba_runtime:start(), null;
        false -> <<"Use wss://your-desk/relay/v1 (ws:// is allowed only on localhost).">>
    end;
command(#{<<"method">> := <<"create_swarm">>} = Request) ->
    swarm_result(ba_swarms:create(maps:get(<<"name">>, Request, <<>>)));
command(#{<<"method">> := <<"join_swarm">>, <<"invitation">> := Invitation}) ->
    case ba_invitation:parse(Invitation) of
        {ok, #{desk := Desk} = Parsed} ->
            case ba_relay:url() of
                Desk -> swarm_result(ba_swarms:join_relay(Parsed));
                _ -> <<"Set this invitation's Reception desk URL first. Changing desks starts a new node session.">>
            end;
        {ok, #{node := Name, cookie := Cookie, swarm := Id, token := Token}} ->
            case command(#{<<"method">> => <<"connect">>, <<"node">> => Name, <<"cookie">> => Cookie}) of
                null -> swarm_result(ba_swarms:join(binary_to_existing_atom(Name), Id, Token));
                Error -> Error
            end;
        _ -> <<"Invalid cluster invitation. Copy a fresh invitation from a cluster member.">>
    end;
command(#{<<"method">> := <<"send_swarm">>, <<"swarm_id">> := Id, <<"text">> := Text}) ->
    swarm_result(ba_swarms:send(Id, Text));
command(#{<<"method">> := <<"leave_swarm">>, <<"swarm_id">> := Id}) ->
    swarm_result(ba_swarms:leave(Id));
command(#{<<"method">> := <<"remove_both">>, <<"swarm_id">> := Id, <<"target">> := Target}) ->
    swarm_result(ba_swarms:remove_both(Id, Target));
command(#{<<"method">> := <<"discover">>, <<"url">> := URL}) ->
    case ba_discovery:discover(URL) of
        ok -> null;
        {error, Error} -> Error
    end;
command(#{<<"method">> := <<"send">>, <<"text">> := Text}) ->
    case ba_runtime:send(Text) of
        {ok, _} -> null;
        {error, _} -> <<"Use 1–4096 bytes of UTF-8 text.">>
    end;
command(#{<<"method">> := <<"connect">>, <<"connection_string">> := String}) ->
    case ba_legacy_connection:parse(String) of
        {ok, #{node := Name, cookie := Cookie}} ->
            command(#{<<"method">> => <<"connect">>, <<"node">> => Name, <<"cookie">> => Cookie});
        {error, _} -> <<"Invalid connection string. Copy a fresh one from the other instance.">>
    end;
command(#{<<"method">> := <<"connect">>, <<"node">> := Name, <<"cookie">> := Cookie})
        when is_binary(Name), byte_size(Name) > 0, byte_size(Name) =< 128,
             is_binary(Cookie), byte_size(Cookie) > 0, byte_size(Cookie) =< 128 ->
    %% Developer-only loopback prototype. Bound the names accepted by the UI.
    case re:run(Name, <<"^ba_(mac|windows)_[0-9]+@127\\.0\\.0\\.1$">>, [{capture, none}]) of
        match ->
            Node = binary_to_atom(Name, utf8),
            erlang:set_cookie(Node, binary_to_atom(Cookie, utf8)),
            case ba_runtime:connect(Node) of
                ok -> null;
                _ -> <<"Could not connect. Check the node name and shared cookie.">>
            end;
        _ -> <<"This build connects to OpenSound app instances on this computer only.">>
    end;
command(_) -> <<"Unsupported request.">>.

snapshot() ->
    Status = ba_runtime:status(),
    #{<<"node">> => case ba_relay:id() of N when is_atom(N) -> atom_to_binary(N); N -> N end,
      <<"relay">> => ba_relay:status(),
      <<"direct">> => ba_direct:snapshot(),
      <<"connection_string">> => case {ba_relay:enabled(), node()} of
          {true, _} -> null;
          {_, nonode@nohost} -> null;
          _ -> ba_legacy_connection:local()
      end,
      <<"network">> => ba_network:snapshot(),
      <<"swarms">> => ba_swarms:snapshot(),
      <<"runtime_info">> => iolist_to_binary(io_lib:format("OTP ~s / ERTS ~s / worker ~p",
          [erlang:system_info(otp_release), erlang:system_info(version), whereis(ba_chat)])),
      <<"known_nodes">> => ba_discovery:nodes(),
      <<"peers">> => [atom_to_binary(N) || N <- maps:get(chat_nodes, Status), N =/= node()],
      <<"messages">> => [message(M) || M <- ba_runtime:history()]}.

swarm_result({ok, Id}) -> {ok, #{swarm_id => Id}};
swarm_result(ok) -> null;
swarm_result({error, Error}) -> Error.

message(#{id := Id, text := Text, sender := Sender, sent_at_ms := Time} = M) ->
    #{<<"id">> => list_to_binary(erlang:ref_to_list(Id)), <<"text">> => Text,
      <<"sender">> => atom_to_binary(Sender), <<"time">> => Time,
      <<"kind">> => atom_to_binary(maps:get(kind, M, user)),
      <<"event">> => atom_to_binary(maps:get(event, M, none)),
      <<"level">> => case maps:find(level, M) of {ok, L} -> atom_to_binary(L); error -> null end}.

close_swarm() ->
    case whereis(ba_swarm) of undefined -> ok;_ -> try ba_swarm:leave() catch exit:_ -> ok end end.
