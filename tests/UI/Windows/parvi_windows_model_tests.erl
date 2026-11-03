-module(parvi_windows_model_tests).
-include_lib("eunit/include/eunit.hrl").

membership_filters_graph_test() ->
    A = <<"a@localhost">>, B = <<"b@localhost">>, C = <<"c@localhost">>,
    State = #{selected => <<"one">>, drafts => #{}, snapshot => #{
        <<"swarms">> => [#{<<"id">> => <<"one">>, <<"members">> => [A, B]},
                          #{<<"id">> => <<"two">>, <<"members">> => [A, C]}],
        <<"network">> => #{<<"nodes">> => [#{<<"id">> => A, <<"state">> => <<"running">>}],
                           <<"edges">> => [[A, B], [A, C]]}}},
    ?assertEqual(#{nodes => [{A, running, observed}, {B, checking, observed}], edges => [{A, B}]},
                 parvi_windows_model:network(State)),
    ?assertEqual(#{nodes => [], edges => []}, parvi_windows_model:network(State#{selected := undefined})).

session_test_() ->
    {setup, fun() ->
        application:set_env(parvi, reception_desk_url, undefined),
        {ok, _} = parvi:start(),
        {ok, Model} = parvi_windows_model:start_link(#{}), Model
    end, fun(Model) -> gen_server:stop(Model), application:stop(parvi) end,
    fun() ->
        Reply = request(#{method => create_swarm}, create),
        A = maps:get(<<"swarm_id">>, maps:get(<<"result">>, Reply)),
        Reply2 = request(#{method => create_swarm}, create),
        B = maps:get(<<"swarm_id">>, maps:get(<<"result">>, Reply2)),
        ?assertEqual(B, maps:get(selected, parvi_windows_model:get())),
        parvi_windows_model:put(#{selected => A, drafts => #{A => "original", B => "other swarm"}}),
        ok = sys:suspend(parvi_swarms),
        Ref = make_ref(),
        try
            parvi_windows_model:request(#{method => send_swarm, swarm_id => A, text => <<"original">>}, send, self(), Ref),
            parvi_windows_model:put(#{selected => B})
        after sys:resume(parvi_swarms) end,
        receive {reply, Ref, send, #{<<"error">> := null}} -> ok after 3000 -> error(send_timeout) end,
        Saved = parvi_windows_model:get(),
        ?assertEqual("other swarm", parvi_windows_model:draft(Saved)),
        ?assertEqual("", maps:get(A, maps:get(drafts, Saved))),
        Swarms = maps:get(<<"swarms">>, maps:get(snapshot, Saved)),
        [ASwarm] = [S || #{<<"id">> := Id} = S <- Swarms, Id =:= A],
        [BSwarm] = [S || #{<<"id">> := Id} = S <- Swarms, Id =:= B],
        ?assertEqual([<<"original">>], [maps:get(<<"text">>, M) || M <- maps:get(<<"messages">>, ASwarm)]),
        ?assertEqual([], maps:get(<<"messages">>, BSwarm)),
        %% An acknowledgment cannot erase a newer draft in the same swarm.
        parvi_windows_model:put(#{selected => A, drafts => #{A => "sent", B => "other swarm"}}),
        ok = sys:suspend(parvi_swarms), Ref2 = make_ref(),
        try
            parvi_windows_model:request(#{method => send_swarm, swarm_id => A, text => <<"sent">>}, send, self(), Ref2),
            parvi_windows_model:put(#{drafts => #{A => "newer", B => "other swarm"}})
        after sys:resume(parvi_swarms) end,
        receive {reply, Ref2, send, _} -> ok after 3000 -> error(send_timeout) end,
        ?assertEqual("newer", parvi_windows_model:draft(parvi_windows_model:get())),
        parvi_windows_model:put(#{incoming => "invalid invitation"}),
        #{<<"error">> := Error} = request(#{method => join_swarm, invitation => <<"invalid invitation">>}, join),
        ?assertNotEqual(null, Error),
        ?assertEqual("invalid invitation", maps:get(incoming, parvi_windows_model:get())),
        %% No membership is required for the node/model to stay alive.
        [request(#{method => leave_swarm, swarm_id => maps:get(id, S)}, leave) || S <- parvi_swarms:snapshot()],
        ?assertEqual(undefined, maps:get(selected, parvi_windows_model:get())),
        ?assert(is_pid(whereis(parvi_swarms))),
        request(#{method => create_swarm}, create),
        ?assertNotEqual(undefined, maps:get(selected, parvi_windows_model:get()))
    end}.

request(Command, Kind) ->
    Ref = make_ref(), parvi_windows_model:request(Command, Kind, self(), Ref),
    receive {reply, Ref, Kind, Reply} -> Reply after 3000 -> error(model_timeout) end.
