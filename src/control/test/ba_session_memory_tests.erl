-module(ba_session_memory_tests).
-include_lib("eunit/include/eunit.hrl").
-define(S,<<"0123456789ABCDEF0123456789ABCDEF">>).
id(C) -> list_to_binary(lists:duplicate(64,C)).

%% The memory only grows: Devices are added, never removed; a kick changes the status.
grows_and_keeps_kicked_devices_test() -> fixture(fun() ->
    ba_contacts:observe(?S,<<"IRON2">>,[id($A),id($B)]),sync(),
    ba_contacts:observe(?S,<<"IRON2">>,[id($A)]),ba_contacts:kicked(?S,id($B)),sync(),
    #{sessions := #{?S := E}}=ba_contacts:list(),
    ?assertEqual(#{id($A) => member,id($B) => kicked},maps:get(devices,E)),
    ?assertEqual(<<"IRON2">>,maps:get(name,E)),
    %% Seen again as a member (re-admitted), it is a member again.
    ba_contacts:observe(?S,<<"IRON2">>,[id($B)]),sync(),
    ?assertEqual(member,maps:get(id($B),maps:get(devices,maps:get(?S,maps:get(sessions,ba_contacts:list()))))),
    ok=ba_contacts:rename_session(?S,<<"Rooftop">>),
    ?assertEqual(<<"Rooftop">>,maps:get(name,maps:get(?S,maps:get(sessions,ba_contacts:list())))),
    %% It is in the settings, so it survives a restart.
    gen_server:stop(ba_contacts),{ok,_}=ba_contacts:start_link(),
    ?assertEqual(<<"Rooftop">>,maps:get(name,maps:get(?S,maps:get(sessions,ba_contacts:list()))))
end).

%% Earlier versions saved each Session as a group named after it; those become Session entries.
old_session_groups_become_sessions_test() -> fixture(fun() ->
    gen_server:stop(ba_contacts),
    ok=ba_settings:put(contacts,#{contacts => #{id($A) => <<"Mac">>},groups => #{<<"GOLDEN">> => [id($A)],<<"Kitchen">> => []},
                                  buffee_groups => #{?S => <<"GOLDEN">>}}),
    {ok,_}=ba_contacts:start_link(),
    L=ba_contacts:list(),
    ?assertEqual(#{<<"Kitchen">> => []},maps:get(groups,L)),
    ?assertEqual(#{name => <<"GOLDEN">>,link => null,devices => #{id($A) => member}},maps:get(?S,maps:get(sessions,L)))
end).

sync() -> _=ba_contacts:list(),ok.
fixture(F) ->
    Old=os:getenv("BA_STATE_DIR"),os:unsetenv("BA_STATE_DIR"),
    {ok,_}=ba_settings:start_link(),{ok,_}=ba_contacts:start_link(),
    try F() after
        [try gen_server:stop(P) catch exit:_ -> ok end || P <- [ba_contacts,ba_settings]],
        case Old of false -> ok;_ -> os:putenv("BA_STATE_DIR",Old) end
    end.

%% Forgetting is the person's choice and removes the whole entry.
forget_removes_the_entry_test() -> fixture(fun() ->
    ba_contacts:observe(?S,<<"IRON2">>,[id($A)]),sync(),
    ok=ba_contacts:forget_session(?S),
    ?assertNot(maps:is_key(?S,maps:get(sessions,ba_contacts:list()))),
    ?assertEqual({error,unknown_session},ba_contacts:forget_session(?S))
end).

forget_survives_background_observation_test() -> fixture(fun() ->
    ba_contacts:observe(?S,<<"IRON2">>,[id($A)]),sync(),
    ok=ba_contacts:forget_session(?S),
    %% A restored worker or a delayed peer update is not the user's Join.
    ba_contacts:observe(?S,<<"IRON2">>,[id($A),id($B)]),sync(),
    ?assertNot(maps:is_key(?S,maps:get(sessions,ba_contacts:list()))),
    ?assertNot(maps:is_key(id($B),maps:get(contacts,ba_contacts:list()))),
    gen_server:stop(ba_contacts),{ok,_}=ba_contacts:start_link(),
    ba_contacts:observe(?S,<<"IRON2">>,[id($A)]),sync(),
    ?assert(ba_contacts:forgotten(?S)),
    ?assertNot(maps:is_key(?S,maps:get(sessions,ba_contacts:list())))
end).

explicit_link_remembers_a_forgotten_session_test() -> fixture(fun() ->
    {Pub,_}=crypto:generate_key(eddsa,ed25519),
    Link=ba_buffee_passport:link(#{<<"authority">> => binary:encode_hex(Pub),
        <<"nonce">> => binary:copy(<<"A">>,32),<<"secret">> => binary:copy(<<"B">>,32),
        <<"desks">> => [<<"ws://127.0.0.1:4000/relay/v1">>]}),
    {_,I}=ba_buffee_passport:parse_invitation(Link),Session=maps:get(<<"buffee">>,I),
    ba_contacts:link(Link),sync(),ok=ba_contacts:forget_session(Session),
    ba_contacts:link(Link),ba_contacts:observe(Session,<<"Revisited">>,[id($A)]),sync(),
    ?assertNot(ba_contacts:forgotten(Session)),
    E=maps:get(Session,maps:get(sessions,ba_contacts:list())),
    ?assertEqual(Link,maps:get(link,E)),
    ?assertEqual(#{id($A) => member},maps:get(devices,E))
end).
