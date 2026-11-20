-module(ba_buffee_tests).
-include_lib("eunit/include/eunit.hrl").
-export([crash_child/0]).
crash_child() -> {ok,spawn_link(fun() -> receive crash -> exit({badmatch,<<"PRIVATE_EXCEPTION">>}) end end)}.

buffee_test_() ->
    {setup,
     fun() ->
         application:load(ba_core),
         Saved=[{K,os:getenv(K)} || K <- ["BA_STATE_DIR","BA_IDENTITY_SEED"]],
         Dir=filename:join("/tmp","ba_ephemeral_unit_"++integer_to_list(erlang:unique_integer([positive]))),
         os:putenv("BA_STATE_DIR",Dir),
         os:putenv("BA_IDENTITY_SEED","0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"),
         {ok,Pid}=ba_sup:start_link(),unlink(Pid),
         {Pid,Saved,Dir}
     end,
     fun({Pid,Saved,Dir}) ->
         gen_server:stop(Pid,shutdown,5000),
         [case V of false -> os:unsetenv(K);_ -> os:putenv(K,V) end || {K,V} <- Saved],
         file:del_dir_r(Dir)
     end,
     [fun idle_and_lifecycle/0,
      fun leave_and_resume_owner/0,
      fun ending_needs_its_own_privilege/0,
      fun bridge_json_protocol/0,
      fun owner_name_in_connection/0,
      fun crash_notice_does_not_block_supervision/0]}.

owner_name_in_connection() ->
    Original=sys:get_state(ba_buffee),
    {Pub,Key}=crypto:generate_key(eddsa,ed25519),Id=binary:encode_hex(Pub),Nonce=binary:copy(<<"A">>,32),
    Link=ba_buffee_passport:invitation(ba_buffee_passport:sign(#{<<"v">> => 1,<<"type">> => <<"invitation">>,
        <<"buffee">> => ba_buffee_passport:session_id(Id,Nonce),<<"authority">> => Id,<<"nonce">> => Nonce,
        <<"secret">> => binary:copy(<<"B">>,64),<<"desks">> => [<<"ws://127.0.0.1:4000/relay/v1">>],<<"name">> => <<"Test">>},Key)),
    Saved=#{name => <<"Test">>,config => #{mode => join,invitation => Link}},
    sys:replace_state(ba_buffee,fun(S) -> S#{remembered := Saved,connection_state := unavailable} end),
    try
        Unknown=ba_buffee:connection(),
        ?assertNotEqual(nomatch,binary:match(maps:get(message,Unknown),<<"Device ",(binary:part(Id,0,12))/binary>>)),
        Name = <<"MacBook Air | A1B2C3D4">>,
        gen_server:cast(ba_buffee,{peer_name,Id,Name}),
        Known=ba_buffee:connection(),
        ?assertEqual(Name,maps:get(owner_name,Known)),
        ?assertNotEqual(nomatch,binary:match(maps:get(message,Known),Name)),
        ?assertEqual(Name,maps:get(owner_name,ba_device_store:load(buffee_connection,#{})))
    after sys:replace_state(ba_buffee,fun(_) -> Original end) end.

crash_notice_does_not_block_supervision() ->
    ok=ba_buffee:create(<<"Crash notice test">>,[<<"ws://127.0.0.1:4000/relay/v1">>]),
    Chat=whereis(ba_buffee_chat),
    {ok,Child}=supervisor:start_child(ba_device_sup,
        #{id => ba_crash_test_child,start => {?MODULE,crash_child,[]},restart => temporary}),
    ok=sys:suspend(Chat),
    try
        Ref=monitor(process,Child),Child ! crash,
        receive {'DOWN',Ref,process,Child,_} -> ok after 500 -> error(failure_blocked) end,
        %% The supervisor must finish processing the child exit while chat is
        %% deliberately suspended. Publication cannot be on its restart path.
        _=gen_server:call(ba_device_sup,which_children,500)
    after sys:resume(Chat) end,
    await_notice(100),
    ok=ba_buffee:end_buffee(),
    ?assertMatch({error,_},logger:get_handler_config(ba_buffee_chat)).
await_notice(0) -> error(no_chat_notice);
await_notice(N) ->
    case ba_buffee_chat:history() of
        [#{text := <<"System: ba_buffee_tests stopped (badmatch).">>}] -> ok;
        _ -> receive after 10 -> ok end,await_notice(N-1)
    end.

idle_and_lifecycle() ->
    ?assertEqual(#{state => idle}, ba_buffee:status()),
    ?assertEqual({error, no_active_buffee}, ba_buffee:end_buffee()),
    ?assertEqual(ok, ba_buffee:leave()),
    URL = <<"ws://127.0.0.1:4000/relay/v1">>,
    ?assertEqual(ok, ba_buffee:create(<<"Living Room Jam">>, [URL])),
    Status = ba_buffee:status(),
    ?assertEqual([],[<<"end_session">>,<<"grant">>,<<"on_air">>]--maps:get(privileges,Status)),
    ?assertEqual(<<"Living Room Jam">>, maps:get(name, Status)),
    ?assertEqual(authorized, maps:get(state, Status)),
    ?assertEqual({error, already_in_buffee}, ba_buffee:create(<<"Another">>, [URL])),
    FriendId = binary:copy(<<"1">>, 64),
    ok = ba_contacts:put(FriendId, <<"Alice">>),
    {ok, Links} = ba_buffee:invite([FriendId], 3600),
    ?assertEqual(1, length(Links)),
    [#{invitation := Link, device := FriendId}] = Links,
    ?assert(is_binary(Link)),
    ?assertEqual(ok, ba_buffee:end_buffee()),
    ?assertEqual(#{state => idle}, ba_buffee:status()).

bridge_json_protocol() ->
    Id = binary:copy(<<"3">>, 64),
    %% The bridge takes the page's commands (ba_device_api:client_methods/0) and refuses the rest.
    Refused = json:decode(ba_bridge:request(json:encode(#{method => <<"list_contacts">>, request_id => <<"r0">>}))),
    ?assertEqual(<<"Unsupported command.">>, maps:get(<<"error">>, Refused)),
    ?assertEqual(<<"r0">>, maps:get(<<"request_id">>, Refused)),
    PutReq = json:encode(#{method => <<"save_contact">>, value => Id, name => <<"Charlie">>}),
    PutRes = json:decode(ba_bridge:request(PutReq)),
    ?assertEqual(null, maps:get(<<"error">>, PutRes)),
    ListReq = json:encode(#{method => <<"snapshot">>}),
    ListRes = json:decode(ba_bridge:request(ListReq)),
    ?assertEqual(null, maps:get(<<"error">>, ListRes)),
    Result = maps:get(<<"contacts">>, ListRes),
    ?assertEqual(<<"Charlie">>, maps:get(Id, maps:get(<<"contacts">>, Result))),
    SnapReq = json:encode(#{method => <<"snapshot">>}),
    SnapRes = json:decode(ba_bridge:request(SnapReq)),
    ?assertEqual(<<"buffee_control">>, maps:get(<<"profile">>, SnapRes)),
    ?assertEqual(#{<<"state">> => <<"idle">>}, maps:get(<<"buffee">>, SnapRes)).

ending_needs_its_own_privilege() ->
    ok=ba_buffee:create(<<"End privilege">>,[<<"ws://127.0.0.1:4000/relay/v1">>]),
    Self=maps:get(id,ba_buffee:status()),End=ba_session_privileges:wire(end_session),
    ok=ba_buffee_membership:take_privilege(Self,End),
    ?assertNot(lists:member(<<"end_session">>,maps:get(privileges,ba_buffee:status()))),
    ?assertEqual({error,end_privilege_required},ba_buffee:end_buffee()),
    ?assertEqual(authorized,maps:get(state,ba_buffee:status())),
    %% A grant holder's own request needs nobody else's approval.
    ok=ba_buffee_membership:request_privilege(End),
    ok=ba_buffee:end_buffee(),?assertEqual(#{state => idle},ba_buffee:status()).
leave_and_resume_owner() ->
    ok=ba_buffee:create(<<"Remember ownership">>,[<<"ws://127.0.0.1:4000/relay/v1">>]),
    Before=ba_buffee:status(),{ok,Link}=ba_buffee_membership:invite(null),
    ok=ba_buffee:leave(),ok=ba_buffee:leave(),?assertEqual(#{state => idle},ba_buffee:status()),
    #{config := #{mode := join,invitation := Link}}=ba_device_store:load(buffee_connection,undefined),
    ok=ba_buffee:join(Link),After=ba_buffee:status(),
    ?assertEqual(maps:get(buffee,Before),maps:get(buffee,After)),
    ?assertEqual([],[<<"end_session">>,<<"grant">>,<<"on_air">>]--maps:get(privileges,After)),
    ok=ba_buffee:leave(),#{config := Config}=ba_device_store:load(buffee_connection,undefined),
    ok=ba_buffee:start(Config),
    ok=ba_buffee:end_buffee(),?assertEqual(undefined,ba_device_store:load(buffee_connection,undefined)).
