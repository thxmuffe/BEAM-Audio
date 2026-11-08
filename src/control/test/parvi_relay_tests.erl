-module(parvi_relay_tests).
-include_lib("eunit/include/eunit.hrl").

bounded_raw_delivery_test() ->
    Frame = iolist_to_binary(json:encode(#{op => <<"delivery">>,from => <<"peer">>,
        mailbox => <<"cap">>,payload => #{swarm => <<"swarm">>}})),
    S = #{owner => self(),delivery => raw,max_owner_queue => 0,
          conn => self(),stream => stream,boxes => #{<<"cap">> => <<"swarm">>}},
    ?assertMatch({noreply,S},parvi_relay:handle_info({gun_ws,self(),stream,{text,Frame}},S)),
    receive {relay,{delivery,_,_,_}} -> error(unbounded_delivery) after 0 -> ok end,
    Allowed = S#{max_owner_queue := 64},
    ?assertMatch({noreply,Allowed},parvi_relay:handle_info({gun_ws,self(),stream,{text,Frame}},Allowed)),
    receive {relay,{delivery,<<"peer">>,<<"cap">>,_}} -> ok after 1000 -> error(no_delivery) end.

network_reconnect_keeps_identity_and_mailboxes_test() ->
    S = #{owner => self(),conn => undefined,stream => old,ready => true,
        online => [<<"peer">>],backoff => 10000,error => null,
        private => <<"identity">>,boxes => #{<<"cap">> => <<"cluster">>},watch => [<<"peer">>]},
    {noreply,Next} = parvi_relay:handle_cast(reconnect,S),
    ?assertEqual(maps:with([private,boxes,watch],S),maps:with([private,boxes,watch],Next)),
    ?assertMatch(#{ready := false,conn := undefined,stream := undefined,online := [],backoff := 500},Next),
    receive {relay,disconnected} -> ok after 1000 -> error(no_disconnect) end,
    receive connect -> ok after 1000 -> error(no_reconnect) end.

desk_url_validation_test() ->
    ?assert(parvi_relay:valid_url(<<"wss://desk.example/relay/v1">>)),
    ?assert(parvi_relay:valid_url(<<"ws://127.0.0.1:8765/relay/v1">>)),
    [?assertNot(parvi_relay:valid_url(U)) || U <- [<<"ws://public.example/relay/v1">>,
        <<"wss://user:secret@desk.example/relay/v1">>, <<"wss://desk.example/relay/v1#secret">>,
        <<"wss://desk.example/relay/v1?x=y">>, <<"wss://desk.example/other">>, <<"not a URL">>]].

relay_invitation_validation_test() ->
    Id = binary:copy(<<"A">>, 32), Key = binary:copy(<<"B">>, 64),
    Q = uri_string:compose_query([{<<"desk">>, <<"wss://desk.example/relay/v1">>},
        {<<"node">>, Key}, {<<"mailbox">>, Id}, {<<"swarm">>, Id}, {<<"token">>, Id}]),
    Link = <<"parvi://swarm/v2?", Q/binary>>,
    ?assertMatch({ok, #{node := Key, mailbox := Id, swarm := Id}}, parvi_invitation:parse(Link)),
    ?assertEqual({error, invalid_invitation}, parvi_invitation:parse(<<Link/binary, "&token=duplicate">>)),
    ?assertEqual({error, invalid_invitation}, parvi_invitation:parse(<<Link/binary, "#fragment">>)).

wire_schema_test() ->
    Id = binary:copy(<<"A">>, 32), Node = binary:copy(<<"B">>, 64),
    M = #{id => Id, node => Node, mailbox => Id, via => none},
    Shared = #{id => Id, name => <<"Example">>, members => #{Node => M}, removed => [], revoked => []},
    Event = {membership, Id, Shared},
    Wire = json:decode(iolist_to_binary(json:encode(parvi_swarm_wire:encode(Id, Event)))),
    ?assertEqual({ok, Id, Event}, parvi_swarm_wire:decode(Wire)),
    ?assertEqual({error, invalid_message}, parvi_swarm_wire:decode(Wire#{<<"sender">> := <<"invalid">>})),
    ?assertEqual({error, invalid_message}, parvi_swarm_wire:decode(#{<<"swarm">> => Id, <<"type">> => <<"execute">>, <<"code">> => <<"halt().">>})),
    Bad = #{<<"swarm">> => Id, <<"type">> => <<"chat">>, <<"sender">> => Id,
            <<"message">> => #{<<"id">> => Id, <<"sender">> => Node, <<"text">> => <<255>>, <<"time">> => 1}},
    ?assertEqual({error, invalid_message}, parvi_swarm_wire:decode(Bad)).
