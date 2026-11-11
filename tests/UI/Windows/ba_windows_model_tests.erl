-module(ba_windows_model_tests).
-include_lib("eunit/include/eunit.hrl").

message_level_filter_test() ->
    Chat = #{<<"text">> => <<"Chat">>, <<"kind">> => <<"user">>},
    Trace = #{<<"text">> => <<"Clock">>, <<"kind">> => <<"system">>,
              <<"event">> => <<"clock_adjusted">>, <<"level">> => null},
    Info = #{<<"text">> => <<"Info">>, <<"kind">> => <<"system">>, <<"level">> => <<"info">>},
    Warning = Info#{<<"text">> := <<"Warning">>, <<"level">> := <<"warning">>},
    Error = Info#{<<"text">> := <<"Error">>, <<"level">> := <<"error">>},
    Messages = [Chat,Trace,Info,Warning,Error],
    ?assertEqual(Messages,os_windows_model:filter_messages(Messages,<<"trace">>)),
    ?assertEqual([Chat,Info,Warning,Error],os_windows_model:filter_messages(Messages,<<"info">>)),
    ?assertEqual([Chat,Warning,Error],os_windows_model:filter_messages(Messages,<<"warning">>)),
    ?assertEqual([Chat,Error],os_windows_model:filter_messages(Messages,<<"error">>)),
    ?assertEqual([Chat],os_windows_model:filter_messages(Messages,<<"none">>)).

membership_filters_graph_test() ->
    A = <<"a@localhost">>, B = <<"b@localhost">>, C = <<"c@localhost">>,
    State = #{selected => <<"one">>, drafts => #{}, snapshot => #{
        <<"buffees">> => [#{<<"id">> => <<"one">>, <<"members">> => [A, B]},
                          #{<<"id">> => <<"two">>, <<"members">> => [A, C]}],
        <<"network">> => #{<<"nodes">> => [#{<<"id">> => A, <<"state">> => <<"running">>}],
                           <<"edges">> => [[A, B], [A, C]]}}},
    ?assertEqual(#{nodes => [{A, running, observed}, {B, checking, observed}], edges => [{A, B}]},
                 os_windows_model:network(State)),
    ?assertEqual(#{nodes => [], edges => []}, os_windows_model:network(State#{selected := undefined})).

session_test_() ->
    {setup, fun() ->
        application:set_env(ba_core, reception_desk_url, undefined),
        {ok, _} = ba_runtime:start(),
        {ok, Model} = os_windows_model:start_link(#{}), Model
    end, fun(Model) -> gen_server:stop(Model), application:stop(ba_core) end,
    fun() ->
        Reply = request(#{method => create_buffee}, create),
        A = maps:get(<<"buffee_id">>, maps:get(<<"result">>, Reply)),
        Reply2 = request(#{method => create_buffee}, create),
        B = maps:get(<<"buffee_id">>, maps:get(<<"result">>, Reply2)),
        ?assertEqual(B, maps:get(selected, os_windows_model:get())),
        os_windows_model:put(#{selected => A, drafts => #{A => "original", B => "other buffee"}}),
        ok = sys:suspend(ba_buffees),
        Ref = make_ref(),
        try
            os_windows_model:request(#{method => send_buffee, buffee_id => A, text => <<"original">>}, send, self(), Ref),
            os_windows_model:put(#{selected => B})
        after sys:resume(ba_buffees) end,
        receive {reply, Ref, send, #{<<"error">> := null}} -> ok after 3000 -> error(send_timeout) end,
        Saved = os_windows_model:get(),
        ?assertEqual("other buffee", os_windows_model:draft(Saved)),
        ?assertEqual("", maps:get(A, maps:get(drafts, Saved))),
        Buffees = maps:get(<<"buffees">>, maps:get(snapshot, Saved)),
        [ABuffee] = [S || #{<<"id">> := Id} = S <- Buffees, Id =:= A],
        [BBuffee] = [S || #{<<"id">> := Id} = S <- Buffees, Id =:= B],
        ?assertEqual([<<"original">>], [maps:get(<<"text">>, M) || M <- maps:get(<<"messages">>, ABuffee)]),
        ?assertEqual([], maps:get(<<"messages">>, BBuffee)),
        %% An acknowledgment cannot erase a newer draft in the same buffee.
        os_windows_model:put(#{selected => A, drafts => #{A => "sent", B => "other buffee"}}),
        ok = sys:suspend(ba_buffees), Ref2 = make_ref(),
        try
            os_windows_model:request(#{method => send_buffee, buffee_id => A, text => <<"sent">>}, send, self(), Ref2),
            os_windows_model:put(#{drafts => #{A => "newer", B => "other buffee"}})
        after sys:resume(ba_buffees) end,
        receive {reply, Ref2, send, _} -> ok after 3000 -> error(send_timeout) end,
        ?assertEqual("newer", os_windows_model:draft(os_windows_model:get())),
        os_windows_model:put(#{incoming => "invalid invitation"}),
        #{<<"error">> := Error} = request(#{method => join_buffee, invitation => <<"invalid invitation">>}, join),
        ?assertNotEqual(null, Error),
        ?assertEqual("invalid invitation", maps:get(incoming, os_windows_model:get())),
        %% No membership is required for the node/model to stay alive.
        [request(#{method => leave_buffee, buffee_id => maps:get(id, S)}, leave) || S <- ba_buffees:snapshot()],
        ?assertEqual(undefined, maps:get(selected, os_windows_model:get())),
        ?assert(is_pid(whereis(ba_buffees))),
        request(#{method => create_buffee}, create),
        ?assertNotEqual(undefined, maps:get(selected, os_windows_model:get()))
    end}.

request(Command, Kind) ->
    Ref = make_ref(), os_windows_model:request(Command, Kind, self(), Ref),
    receive {reply, Ref, Kind, Reply} -> Reply after 3000 -> error(model_timeout) end.

runtime_notifications_test_() ->
    {setup,fun() ->
        Keys=[reception_desk_url,clock_reference,clock_upstream],
        Saved=[{K,application:get_env(ba_core,K)} || K<-Keys],
        application:set_env(ba_core,reception_desk_url,undefined),
        application:set_env(ba_core,clock_reference,system),
        application:set_env(ba_core,clock_upstream,system),
        {ok,_}=ba_runtime:start(),
        {ok,Model}=os_windows_model:start_link(#{}),
        {Model,Saved}
    end,fun({Model,Saved}) ->
        gen_server:stop(Model),application:stop(ba_core),
        [case V of undefined->application:unset_env(ba_core,K);
            {ok,X}->application:set_env(ba_core,K,X) end || {K,V}<-Saved]
    end,fun() ->
        _=os_windows_model:watch(),
        await_model(fun(S)->map_size(maps:get(snapshot,S))>0 andalso settled(S) end),
        timer:sleep(350),
        await_model(fun settled/1),
        Before=maps:get(serial,os_windows_model:get()),
        timer:sleep(900),
        Idle=os_windows_model:get(),
        ?assertEqual(Before,maps:get(serial,Idle)),
        ?assertEqual(undefined,maps:get(audio_timer,Idle)),
        [ba_events:notify(test) || _<-lists:seq(1,100)],
        await_model(fun(S)->maps:get(serial,S)>Before andalso settled(S) end),
        ?assert(maps:get(serial,os_windows_model:get())-Before=<2),
        {ok,Id}=ba_buffees:create(<<"External change">>),
        await_model(fun(S)->lists:any(fun(#{<<"id">>:=I})->I=:=Id end,
            maps:get(<<"buffees">>,maps:get(snapshot,S),[])) end),
        ok=ba_buffees:send(Id,<<"Event-driven history">>),
        await_model(fun(S)->lists:any(fun(Buffee)->
            lists:any(fun(#{<<"text">>:=T})->T=:=<<"Event-driven history">> end,
                maps:get(<<"messages">>,Buffee,[])) end,
            maps:get(<<"buffees">>,maps:get(snapshot,S),[])) end),
        OldPg=whereis(ba_pg),exit(OldPg,kill),
        await_model(fun(S)->is_reference(maps:get(runtime_monitor,S)) andalso
            is_pid(whereis(ba_pg)) andalso whereis(ba_pg)=/=OldPg andalso settled(S) end),
        {ok,NewId}=ba_buffees:create(<<"After scope restart">>),
        await_model(fun(S)->lists:any(fun(#{<<"id">>:=I})->I=:=NewId end,
            maps:get(<<"buffees">>,maps:get(snapshot,S),[])) end)
    end}.

settled(S) -> map_size(maps:get(pending,S))=:=0 andalso maps:get(refresh_timer,S)=:=undefined.
await_model(Fun) -> await_model(Fun,300).
await_model(_,0) -> error(model_did_not_converge);
await_model(Fun,N) ->
    case Fun(os_windows_model:get()) of
        true->ok;false->timer:sleep(10),await_model(Fun,N-1)
    end.
