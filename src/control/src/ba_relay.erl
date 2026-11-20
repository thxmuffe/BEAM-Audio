%% Outbound, authenticated WebSocket connection to one Reception, signed with
%% this Device's identity. Owners (ba_buffee_desks of each Session) attach
%% mailboxes and watches by pid; events go to them as {relay,URL,Event}.
-module(ba_relay).
-behaviour(gen_server).
-export([start_link/1, valid_url/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, format_status/1]).
start_link(Options) -> gen_server:start_link(?MODULE,Options,[]).
valid_url(URL) when is_binary(URL), byte_size(URL) =< 512 ->
    try
        #{scheme := Scheme, host := Host} = Map = uri_string:parse(URL),
        true = byte_size(Host) > 0,
        false = maps:is_key(userinfo, Map) orelse maps:is_key(fragment, Map) orelse maps:is_key(query, Map),
        true = Scheme =:= <<"wss">> orelse
               (Scheme =:= <<"ws">> andalso lists:member(Host, [<<"127.0.0.1">>, <<"localhost">>, <<"::1">>])),
        true = lists:member(maps:get(path, Map, <<>>), [<<"/reception">>, <<"/relay/v1">>]),
        true = maps:get(port, Map, 443) > 0 andalso maps:get(port, Map, 443) < 65536,
        true
    catch _:_ -> false end;
valid_url(_) -> false.
init(#{owner := Owner, url := URL}) ->
    true = valid_url(URL),
    {Pub, Private} = ba_device_store:identity(),
    self() ! connect,
    {ok, #{owner => Owner, identity => binary:encode_hex(Pub), url => URL, private => Private,
           conn => undefined, stream => undefined, ready => false, boxes => #{}, lookups => #{},
           watch => [], online => [], backoff => 500, error => null}}.
handle_call(status, _, S) ->
    {reply, #{id => maps:get(identity,S),url => maps:get(url,S),
              connected => maps:get(ready, S), online => maps:get(online, S), watched => maps:get(watch, S), error => maps:get(error, S),diagnostics => ba_diagnostics:view(S)}, S};
handle_call({send, To, Cap, Payload}, _, #{ready := true} = S) ->
    Frame = #{op => <<"send">>, to => To, mailbox => Cap, payload => Payload,
              request => maps:get(<<"request">>, Payload, null)},
    {reply, ws(Frame, S), S};
handle_call({send, _, _, _}, _, S) -> {reply, {error, disconnected}, S};
handle_call({lookup,Buffee,Cap},From,#{ready := true,lookups := Pending}=S) when map_size(Pending)<16 ->
    Request=binary:encode_hex(crypto:strong_rand_bytes(16)),
    case ws(#{op => <<"lookup">>,request => Request,buffee => Buffee,mailbox => Cap},S) of
        ok -> erlang:send_after(3000,self(),{lookup_timeout,Request}),
              {noreply,S#{lookups := Pending#{Request => From}}};
        Error -> {reply,Error,S}
    end;
handle_call({lookup,_,_},_,S) -> {reply,{error,disconnected},S}.
handle_cast({open,Buffee,Cap,Owner},S) when is_pid(Owner) ->
    Owners=maps:get(mailbox_owners,S,#{}),
    case lists:member(Owner,maps:values(Owners)) of false -> monitor(process,Owner);true -> ok end,
    handle_cast({open,Buffee,Cap},S#{mailbox_owners => Owners#{Cap => Owner}});
handle_cast({watch,Nodes,Owner},S) when is_pid(Owner) ->
    Watches=(maps:get(owner_watches,S,#{}))#{Owner => Nodes},
    handle_cast({watch,lists:usort(lists:append(maps:values(Watches)))},S#{owner_watches => Watches});
handle_cast({detach,Owner},S) ->
    Owners=maps:get(mailbox_owners,S,#{}),Caps=[Cap || {Cap,P} <- maps:to_list(Owners),P=:=Owner],
    Next=lists:foldl(fun(Cap,Acc) -> {noreply,N}=handle_cast({close,Cap},Acc),N end,S,Caps),
    Watches=maps:remove(Owner,maps:get(owner_watches,S,#{})),
    handle_cast({watch,lists:usort(lists:append(maps:values(Watches)))},
        Next#{mailbox_owners => maps:without(Caps,Owners),owner_watches => Watches});
handle_cast({open, Buffee, Cap}, #{boxes := Boxes} = S) ->
    Next = S#{boxes := Boxes#{Cap => Buffee}}, maybe_ws(#{op => <<"open">>, buffee => Buffee, mailbox => Cap}, Next), {noreply, Next};
handle_cast({close, Cap}, #{boxes := Boxes} = S) ->
    maybe_ws(#{op => <<"close">>, mailbox => Cap}, S), {noreply, S#{boxes := maps:remove(Cap, Boxes)}};
handle_cast({watch, Nodes}, S) ->
    Next = S#{watch := lists:sublist(lists:usort([N || N <- Nodes, is_binary(N)]), 256)},
    maybe_ws(#{op => <<"watch">>, nodes => maps:get(watch, Next)}, Next), {noreply, Next};
handle_cast(_, S) -> {noreply, S}.
handle_info(connect, #{conn := undefined, url := URL} = S) when is_binary(URL) ->
    #{scheme := Scheme, host := Host} = U = uri_string:parse(URL),
    TLS = Scheme =:= <<"wss">>, Port = maps:get(port, U, case TLS of true -> 443; false -> 80 end),
    try
        Opts = #{protocols => [http], retry => 0, connect_timeout => 5000,
                 domain_lookup_timeout => 5000, tls_handshake_timeout => 5000,
                 transport => case TLS of true -> tls; false -> tcp end},
        ResolvedOpts = case ba_settings:app(relay_resolver) of
            undefined -> Opts;
            {ok, {Module, Function}} ->
                {ok, Family} = Module:Function(Host), Opts#{tcp_opts => [Family]}
        end,
        Options = case TLS of true -> ResolvedOpts#{tls_opts => tls_options()}; false -> ResolvedOpts end,
        {ok, Pid} = gun:open(binary_to_list(Host), Port, Options),
        monitor(process, Pid),
        erlang:send_after(10000, self(), {handshake_timeout, Pid}),
        {noreply, S#{conn := Pid}}
    catch _:_ -> {noreply, retry(connect_failed,S)} end;
handle_info({gun_up, Pid, http}, #{conn := Pid} = S) ->
    Stream = gun:ws_upgrade(Pid, "/relay/v1", [],
        #{max_frame_size => 131072, compress => false}),
    {noreply, S#{stream := Stream}};
handle_info({gun_upgrade, Pid, Stream, [<<"websocket">>], _}, #{conn := Pid, stream := Stream} = S) -> {noreply, S};
handle_info({gun_ws, Pid, Stream, {text, Text}}, #{conn := Pid, stream := Stream} = S) when byte_size(Text) =< 131072 ->
    try {noreply, incoming(json:decode(Text), S)} catch _:_ -> {noreply, retry(invalid_desk_message,S)} end;
handle_info({gun_down, Pid, _, Reason, _}, #{conn := Pid} = S) -> {noreply, retry(Reason,S)};
handle_info({'DOWN', _, process, Pid, _}, #{conn := Pid} = S) -> {noreply, retry(connection_closed,S)};
handle_info({'DOWN',_,process,Owner,_},S) -> handle_cast({detach,Owner},S);
handle_info({handshake_timeout, Pid}, #{conn := Pid, ready := false} = S) -> {noreply, retry(handshake_timeout,S)};
handle_info({gun_error, Pid, _, Reason}, #{conn := Pid} = S) -> {noreply, retry(Reason,S)};
handle_info({gun_error, Pid, Reason}, #{conn := Pid} = S) -> {noreply, retry(Reason,S)};
handle_info({gun_response, Pid, _, _, _, _}, #{conn := Pid} = S) -> {noreply, retry(http_upgrade_rejected,S)};
handle_info({lookup_timeout,Request},S) -> {noreply,lookup_reply(Request,{error,lookup_timeout},S)};
handle_info(_, S) -> {noreply, S}.
incoming(#{<<"op">> := <<"challenge">>, <<"v">> := 1, <<"nonce">> := Nonce}, S)
        when is_binary(Nonce), byte_size(Nonce) =:= 64 ->
    Sig = crypto:sign(eddsa, none, <<"beamaudio-desk/v1:", Nonce/binary>>, [maps:get(private, S), ed25519]),
    ok = ws(#{op => <<"hello">>,v => 1,id => maps:get(identity,S),signature => binary:encode_hex(Sig)},S),S;
incoming(#{<<"op">> := <<"ready">>, <<"v">> := 1, <<"id">> := Id}, S) ->
    Id = maps:get(identity,S), Next = S#{ready := true, backoff := 500, error := null},
    [ws(#{op => <<"open">>, buffee => Buffee, mailbox => Cap}, Next) || {Cap, Buffee} <- maps:to_list(maps:get(boxes, S))],
    ws(#{op => <<"watch">>, nodes => maps:get(watch, S)}, Next),
    notify(connected, Next), Next;
incoming(#{<<"op">> := <<"delivery">>, <<"from">> := From, <<"mailbox">> := Cap, <<"payload">> := Payload}, #{boxes := Boxes} = S) ->
    Delivery = case {maps:find(Cap, Boxes), Payload} of
        {{ok, Buffee}, #{<<"buffee">> := Buffee}} -> notify({delivery, From, Cap, Payload}, S);
        _ -> ok
    end,
    case Delivery of {error,overloaded} -> ba_diagnostics:count(desk_owner_overloaded,S);_ -> S end;
incoming(#{<<"op">> := <<"presence">>, <<"online">> := Online}, S) when is_list(Online), length(Online) =< 256 ->
    notify({presence, Online}, S), S#{online := Online};
incoming(#{<<"op">> := <<"found">>,<<"request">> := Request,<<"owners">> := Owners},S)
        when is_list(Owners),length(Owners)=<16 ->
    true=lists:all(fun(Id) -> ba_buffee_job:hex(Id,64) end,Owners),
    lookup_reply(Request,{ok,Owners},S);
incoming(#{<<"op">> := <<"error">>, <<"request">> := Request, <<"error">> := Error}, S) ->
    notify({error, Request, Error}, S), lookup_reply(Request,{error,Error},S#{error := Error});
incoming(_, S) -> S.
lookup_reply(Request,Reply,S) ->
    case maps:take(Request,maps:get(lookups,S,#{})) of
        {From,Rest} -> gen_server:reply(From,Reply),S#{lookups := Rest};
        error -> S
    end.
retry(Reason,S) -> retry(ba_diagnostics:count(Reason,S)).
retry(#{conn := Pid, backoff := Delay} = S) ->
    maps:foreach(fun(_,From) -> gen_server:reply(From,{error,disconnected}) end,maps:get(lookups,S,#{})),
    case Pid of undefined -> ok; _ -> try gun:close(Pid) catch _:_ -> ok end end,
    erlang:send_after(Delay + rand:uniform(250), self(), connect), notify(disconnected, S),
    S#{conn := undefined, stream := undefined, ready := false, online := [],lookups := #{},
       error := <<"Connection failed. Check the desk URL and TLS trust.">>, backoff := min(10000, Delay * 2)}.
maybe_ws(Msg, #{ready := true} = S) -> ws(Msg, S);
maybe_ws(_, _) -> ok.
ws(Msg, #{conn := Pid, stream := Stream}) ->
    Data = iolist_to_binary(json:encode(Msg)),
    case byte_size(Data) =< 131072 of
        true ->
            case process_info(Pid, message_queue_len) of
                {message_queue_len, N} when N < 256 -> gun:ws_send(Pid, Stream, {text, Data});
                _ -> {error, overloaded}
            end;
        false -> {error, too_large}
    end.
%% Mailbox deliveries go to that mailbox's owner; other events to every owner.
notify({delivery,_,Cap,_}=Event,S) ->
    deliver(maps:get(Cap,maps:get(mailbox_owners,S,#{}),maps:get(owner,S)),Event,S);
notify(Event,S) ->
    [deliver(P,Event,S) || P <- lists:usort([maps:get(owner,S)|maps:values(maps:get(mailbox_owners,S,#{}))])],ok.
deliver(P,Event,#{url := URL}) ->
    case process_info(P,message_queue_len) of
        {message_queue_len,N} when N<64 -> P ! {relay,URL,Event},ok;
        _ -> {error,overloaded}
    end.
tls_options() ->
    Setting = case ba_settings:env("BA_RELAY_CA_FILE") of
        false -> ba_settings:app(relay_cacertfile);
        Path0 -> {ok, Path0}
    end,
    CA = case Setting of
        {ok, Path} -> [{cacertfile, Path}];
        undefined -> [{cacerts, public_key:cacerts_get()}]
    end,
    [{verify, verify_peer}, {depth, 10},
     {customize_hostname_check, [{match_fun, public_key:pkix_verify_hostname_match_fun(https)}]} | CA].
terminate(_, #{conn := Pid}) -> case Pid of undefined -> ok; _ -> try gun:close(Pid) catch _:_ -> ok end end, ok.

format_status(Status) ->
    maps:map(fun(state,S) -> maps:with([url,ready,backoff,error],S);
                (log,_) -> []; (_,_) -> redacted end,Status).
