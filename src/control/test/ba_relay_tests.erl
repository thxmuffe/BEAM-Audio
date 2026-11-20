-module(ba_relay_tests).
-include_lib("eunit/include/eunit.hrl").

bounded_delivery_test() ->
    URL = <<"wss://desk.example/relay/v1">>,
    Frame = iolist_to_binary(json:encode(#{op => <<"delivery">>,from => <<"peer">>,
        mailbox => <<"cap">>,payload => #{session => <<"session">>}})),
    S = #{owner => self(),url => URL,conn => self(),stream => stream,boxes => #{<<"cap">> => <<"session">>}},
    %% An owner with a full mailbox is not sent more.
    [self() ! filler || _ <- lists:seq(1,64)],
    ?assertMatch({noreply,#{diagnostics := #{last_error := desk_owner_overloaded}}},
                 ba_relay:handle_info({gun_ws,self(),stream,{text,Frame}},S)),
    [receive filler -> ok end || _ <- lists:seq(1,64)],
    receive {relay,_,{delivery,_,_,_}} -> error(unbounded_delivery) after 0 -> ok end,
    ?assertMatch({noreply,S},ba_relay:handle_info({gun_ws,self(),stream,{text,Frame}},S)),
    receive {relay,URL,{delivery,<<"peer">>,<<"cap">>,_}} -> ok after 1000 -> error(no_delivery) end.

desk_url_validation_test() ->
    ?assert(ba_relay:valid_url(<<"wss://beamaudio.onrender.com/reception">>)),
    ?assertNot(ba_relay:valid_url(<<"wss://beamaudio.onrender.com/">>)),
    ?assert(ba_relay:valid_url(<<"wss://desk.example/relay/v1">>)),
    ?assert(ba_relay:valid_url(<<"ws://127.0.0.1:8765/relay/v1">>)),
    [?assertNot(ba_relay:valid_url(U)) || U <- [<<"ws://public.example/relay/v1">>,
        <<"wss://user:secret@desk.example/relay/v1">>, <<"wss://desk.example/relay/v1#secret">>,
        <<"wss://desk.example/relay/v1?x=y">>, <<"wss://desk.example/other">>, <<"not a URL">>]].
