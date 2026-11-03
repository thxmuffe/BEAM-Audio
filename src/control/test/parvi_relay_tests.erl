-module(parvi_relay_tests).
-include_lib("eunit/include/eunit.hrl").

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
