-module(parvi_audio_subscription_intent_tests).
-include_lib("eunit/include/eunit.hrl").
-export([start_output/2]).

intent() -> parvi_audio_subscription_intent:new(<<"cluster">>,<<"publisher">>,offer(),channel).
offer() -> #{id => <<"temporary-id">>,name => <<"Music">>,source_key => <<"default-output">>,
    profiles => #{channel => #{}}}.

source_restart_keeps_identity_test() ->
    I = intent(), O = (offer())#{id := <<"new-id">>,name := <<"New display name">>},
    ?assert(parvi_audio_subscription_intent:matches(I,<<"publisher">>,O)),
    ?assertNot(parvi_audio_subscription_intent:matches(I,<<"another-node">>,O)),
    ?assertNot(parvi_audio_subscription_intent:matches(I,<<"publisher">>,O#{source_key := <<"microphone">>})),
    ?assertNot(parvi_audio_subscription_intent:matches(I,<<"publisher">>,O#{profiles := #{point => #{}}})).

fresh_clock_required_after_resume_test() ->
    Clock = #{filter_ready => true,last_sync => 100,age_ns => 0},
    ?assertNot(parvi_audio_subscription_intent:clock_ready(Clock,101)),
    ?assert(parvi_audio_subscription_intent:clock_ready(Clock#{last_sync := 102},101)),
    ?assertNot(parvi_audio_subscription_intent:clock_ready(Clock#{age_ns := 11000000000},undefined)),
    ?assertNot(parvi_audio_subscription_intent:clock_ready(Clock#{filter_ready := false},undefined)),
    ?assert(parvi_audio_subscription_intent:clock_ready(#{role => master,filtered_utc_time => 1000},101)).

save_restore_and_unsubscribe_test() ->
    with_store(fun() ->
        I = (intent())#{playing := true},
        ok = parvi_audio_subscription_intent:save(I),
        ?assertEqual(I,parvi_audio_subscription_intent:load()),
        S = state(I),
        {reply,ok,Paused} = parvi_audio_receiver:handle_call({playback,stop},ignored,S),
        ?assertEqual(false,maps:get(playing,maps:get(intent,Paused))),
        ?assertEqual(maps:get(intent,Paused),parvi_audio_subscription_intent:load()),
        {reply,ok,Stopped} = parvi_audio_receiver:handle_call(stop,ignored,Paused),
        ?assertEqual(undefined,maps:get(intent,Stopped)),
        ?assertEqual(undefined,parvi_audio_subscription_intent:load())
    end).

suspension_preserves_intent_but_discards_session_state_test() ->
    with_store(fun() ->
        I = (intent())#{playing := true},
        ok = parvi_audio_subscription_intent:save(I),
        {reply,ok,Suspended} = parvi_audio_receiver:handle_call(suspend,ignored,
            (state(I))#{native_statistics => #{old_target => 10}}),
        ?assertEqual(I,maps:get(intent,Suspended)),
        ?assertEqual(I,parvi_audio_subscription_intent:load()),
        ?assertEqual(true,maps:get(suspended,Suspended)),
        ?assertNot(maps:is_key(native_statistics,Suspended)),
        ?assertEqual(undefined,maps:get(session,maps:get(receive_state,Suspended))),
        {noreply,StillSuspended} = parvi_audio_receiver:handle_info(restore_subscription,Suspended),
        ?assertEqual(Suspended,StillSuspended),
        receive restore_subscription -> ok after 1100 -> error(missing_retry) end
    end).

forget_clears_saved_intent_test() ->
    with_store(fun() ->
        ok = parvi_audio_subscription_intent:save(intent()),
        {reply,ok,S} = parvi_audio_receiver:handle_call(forget_subscription,ignored,state(intent())),
        ?assertEqual(undefined,maps:get(intent,S)),
        ?assertEqual(undefined,parvi_audio_subscription_intent:load())
    end).

state(I) -> #{intent => I,suspended => false,handler => parvi_audio_stream_handler_webrtc,
    receive_state => #{state => stopped,session => undefined,packets => 0,frames => 0,bytes => 0},
    output => undefined,playback => #{state => <<"stopped">>}}.
with_store(Fun) ->
    Dir = filename:join("/tmp","parvi-subscription-"++integer_to_list(erlang:unique_integer([positive]))),
    Saved = [{K,os:getenv(K)} || K <- ["PARVI_STATE_DIR","PARVI_IDENTITY_SEED"]],
    try
        os:putenv("PARVI_STATE_DIR",Dir),os:putenv("PARVI_IDENTITY_SEED","test-only"),Fun()
    after
        [case V of false -> os:unsetenv(K); _ -> os:putenv(K,V) end || {K,V} <- Saved],
        file:delete(filename:join(Dir,"audio_subscription.term")),file:del_dir(Dir)
    end.

supervised_receiver_reloads_intent_test() ->
    with_store(fun() ->
        ok = parvi_audio_subscription_intent:save(intent()),
        {ok,Pg} = pg:start_link(parvi_pg),
        {ok,Sup} = parvi_audio_sup:start_link(),
        try
            Old = whereis(parvi_audio_receiver), Ref = monitor(process,Old),
            exit(Old,kill), receive {'DOWN',Ref,process,Old,killed} -> ok after 1000 -> error(not_down) end,
            New = await_receiver(Old,100),
            ?assert(is_pid(New)),
            View = gen_server:call(New,snapshot),
            ?assertMatch(#{receiver := #{saved_subscription := true,state := <<"waiting_for_source">>}},View),
            ?assertEqual(intent(),parvi_audio_subscription_intent:load())
        after
            gen_server:stop(Sup),gen_server:stop(Pg)
        end
    end).
await_receiver(_,0) -> error(receiver_not_restarted);
await_receiver(Old,N) ->
    case whereis(parvi_audio_receiver) of
        Pid when is_pid(Pid),Pid =/= Old -> Pid;
        _ -> receive after 10 -> await_receiver(Old,N-1) end
    end.

%% Ready acknowledgements exercise the real receiver's restore policy. Only the
%% device start operation and chat logging endpoint are substituted.
restore_playing_or_paused_after_ready_test_() ->
    [fun() -> ready_restore(Playing) end || Playing <- [false,true]].
ready_restore(Playing) ->
    Chat = spawn(fun() -> receive {'$gen_call',From,_} -> gen_server:reply(From,ok),
        receive stop -> ok end end end),
    true = register(parvi_chat,Chat),
    Session = spawn(fun() -> receive {'$gen_call',From,ready} -> gen_server:reply(From,ok),
        receive stop -> ok end end end),
    try
        Id = gen_statem:send_request(Session,ready),
        Message = receive {Tag,ok} = M when is_reference(Tag); is_list(Tag) -> M
            after 1000 -> error(missing_ready_reply) end,
        S = state((intent())#{playing := Playing}),
        R = (maps:get(receive_state,S))#{state := activating,session := Session,pending => Id,
            descriptor => #{},source_id => <<"new-publication-id">>,source_name => <<"Music">>},
        {noreply,Next} = parvi_audio_receiver:handle_info(Message,S#{receive_state := R,handler := ?MODULE}),
        ?assertEqual(active,maps:get(state,maps:get(receive_state,Next))),
        case Playing of
            true ->
                receive restore_output_called -> ok after 1000 -> error(playback_not_restored) end,
                {_,Ref} = maps:get(output,Next),demonitor(Ref,[flush]);
            false ->
                ?assertEqual(undefined,maps:get(output,Next)),
                receive restore_output_called -> error(paused_subscription_started) after 0 -> ok end
        end
    after exit(Chat,kill),exit(Session,kill) end.
start_output(_,_) -> self() ! restore_output_called,{ok,self()}.
