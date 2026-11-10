-module(ba_swarm_tests).
-include_lib("eunit/include/eunit.hrl").
-export([crash_child/0]).
crash_child() -> {ok,spawn_link(fun() -> receive crash -> exit({badmatch,<<"PRIVATE_EXCEPTION">>}) end end)}.

swarm_test_() ->
    {setup,
     fun() ->
         application:load(ba_core),
         Profile=application:get_env(ba_core,runtime_profile),
         Saved=[{K,os:getenv(K)} || K <- ["BA_STATE_DIR","BA_IDENTITY_SEED"]],
         Dir=filename:join("/tmp","ba_ephemeral_unit_"++integer_to_list(erlang:unique_integer([positive]))),
         os:putenv("BA_STATE_DIR",Dir),
         os:putenv("BA_IDENTITY_SEED","0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"),
         application:set_env(ba_core,runtime_profile,swarm_control),
         {ok,Pid}=ba_sup:start_link(),unlink(Pid),
         {Pid,Saved,Profile,Dir}
     end,
     fun({Pid,Saved,Profile,Dir}) ->
         gen_server:stop(Pid,shutdown,5000),
         [case V of false -> os:unsetenv(K);_ -> os:putenv(K,V) end || {K,V} <- Saved],
         case Profile of undefined -> application:unset_env(ba_core,runtime_profile);
             {ok,P} -> application:set_env(ba_core,runtime_profile,P) end,
         file:del_dir_r(Dir)
     end,
     [fun idle_and_lifecycle/0,
      fun bridge_json_protocol/0,
      fun crash_notice_does_not_block_supervision/0]}.

crash_notice_does_not_block_supervision() ->
    ok=ba_swarm:create(<<"Crash notice test">>,[<<"ws://127.0.0.1:4000/relay/v1">>]),
    Chat=whereis(ba_swarm_chat),
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
    ok=ba_swarm:end_swarm(),
    ?assertMatch({error,_},logger:get_handler_config(ba_swarm_chat)).
await_notice(0) -> error(no_chat_notice);
await_notice(N) ->
    case ba_swarm_chat:history() of
        [#{text := <<"System: ba_swarm_tests stopped (badmatch).">>}] -> ok;
        _ -> receive after 10 -> ok end,await_notice(N-1)
    end.

idle_and_lifecycle() ->
    ?assertEqual(#{state => idle}, ba_swarm:status()),
    ?assertEqual({error, no_active_swarm}, ba_swarm:end_swarm()),
    ?assertEqual(ok, ba_swarm:leave()),
    URL = <<"ws://127.0.0.1:4000/relay/v1">>,
    ?assertEqual(ok, ba_swarm:create(<<"Living Room Jam">>, [URL])),
    Status = ba_swarm:status(),
    ?assertEqual(authority, maps:get(role, Status)),
    ?assertEqual(<<"Living Room Jam">>, maps:get(name, Status)),
    ?assertEqual(authorized, maps:get(state, Status)),
    ?assertEqual({error, already_in_swarm}, ba_swarm:create(<<"Another">>, [URL])),
    FriendId = binary:copy(<<"1">>, 64),
    ok = ba_contacts:put(FriendId, <<"Alice">>),
    {ok, Links} = ba_swarm:invite([FriendId], 3600),
    ?assertEqual(1, length(Links)),
    [#{invitation := Link, device := FriendId}] = Links,
    ?assert(is_binary(Link)),
    ?assertEqual(ok, ba_swarm:end_swarm()),
    ?assertEqual(#{state => idle}, ba_swarm:status()).

bridge_json_protocol() ->
    Id = binary:copy(<<"3">>, 64),
    PutReq = json:encode(#{method => <<"put_contact">>, id => Id, name => <<"Charlie">>}),
    PutRes = json:decode(ba_bridge:request(PutReq)),
    ?assertEqual(null, maps:get(<<"error">>, PutRes)),
    ListReq = json:encode(#{method => <<"list_contacts">>}),
    ListRes = json:decode(ba_bridge:request(ListReq)),
    ?assertEqual(null, maps:get(<<"error">>, ListRes)),
    Result = maps:get(<<"result">>, ListRes),
    ?assertEqual(<<"Charlie">>, maps:get(Id, maps:get(<<"contacts">>, Result))),
    SnapReq = json:encode(#{method => <<"snapshot">>}),
    SnapRes = json:decode(ba_bridge:request(SnapReq)),
    ?assertEqual(<<"swarm_control">>, maps:get(<<"profile">>, SnapRes)),
    ?assertEqual(#{<<"state">> => <<"idle">>}, maps:get(<<"swarm">>, SnapRes)).
