-module(ba_audio_restore_events_tests).
-include_lib("eunit/include/eunit.hrl").
-export([status/0]).
status() -> get(test_clock).
restore_requires_fresh_clock_and_local_contract_test() ->
    fixture(fun(S,Id) ->
        put(test_clock,#{state => synchronized,filter_ready => true,last_sync => 99,age_ns => 0}),
        {noreply,NoClock} = ba_audio_receiver:handle_info(tick,S),
        ?assertEqual(waiting_for_source,maps:get(state,maps:get(Id,maps:get(subscriptions,NoClock)))),
        no_attempt(),
        put(test_clock,#{state => synchronized,filter_ready => true,last_sync => 101,age_ns => 0}),
        {noreply,_} = ba_audio_receiver:handle_info(tick,S#{contracts := #{}}),no_attempt(),
        {noreply,Opening} = ba_audio_receiver:handle_info(tick,S),
        receive {attempt,Id,#{<<"kind">> := <<"subscribe">>,<<"contract">> := C}} ->
            ?assertEqual(binary:copy(<<"C">>,32),C) after 1000 -> error(no_authorized_attempt) end,
        {noreply,_} = ba_audio_receiver:handle_info(tick,Opening),no_attempt(),
        {noreply,_} = ba_audio_receiver:handle_info(tick,S#{suspended := true}),no_attempt()
    end).
no_attempt() -> receive {attempt,_,_} -> error(unexpected_attempt) after 0 -> ok end.

missing_opus_backend_keeps_intent_without_starting_transport_test() ->
    Saved = os:getenv("BA_GSTREAMER_PCM_HELPER"),os:unsetenv("BA_GSTREAMER_PCM_HELPER"),
    try fixture(fun(S,Id) ->
        put(test_clock,#{state => synchronized,filter_ready => true,last_sync => 101,age_ns => 0}),
        Offers = maps:map(fun(_,O) -> O#{profiles := #{channel => #{encoding => opus}}} end,maps:get(offers,S)),
        {noreply,Next} = ba_audio_receiver:handle_info(tick,S#{offers := Offers}),
        ?assertMatch(#{state := waiting_for_backend,error := opus_decoder_unavailable,session := undefined},
            maps:get(Id,maps:get(subscriptions,Next))),no_attempt()
    end) after
        case Saved of false -> os:unsetenv("BA_GSTREAMER_PCM_HELPER");_ -> os:putenv("BA_GSTREAMER_PCM_HELPER",Saved) end
    end.
fixture(Fun) ->
    I = ba_subscription_tests:intent(<<"music">>),Id = maps:get(id,I),Peer = maps:get(device,I),
    Context = #{peer => Peer,session => binary:copy(<<"D">>,32),swarm => maps:get(swarm,I),deadline => erlang:monotonic_time(millisecond)+10000},
    Parent = self(),Control = spawn(fun Loop() -> receive
        {'$gen_call',From,{audio_context,_}} -> gen_server:reply(From,{ok,Context}),Loop();
        {'$gen_call',From,{audio_message,_,Request,P}} -> Parent ! {attempt,Request,P},gen_server:reply(From,ok),Loop()
    end end),true = register(ba_swarm_control,Control),
    Old = application:get_env(ba_core,audio_clock_adapter),application:set_env(ba_core,audio_clock_adapter,?MODULE),
    R = #{intent => I,state => waiting_for_source,session => undefined,retry_at => erlang:monotonic_time(millisecond)-1,packets => 0},
    D = #{sample_rate => 48000,sample_format => float32_le,channel_count => 2,clock => <<"test">>},
    S = #{subscriptions => #{Id => R},offers => #{{Peer,<<"music">>} => #{incarnation => binary:copy(<<"E">>,32),profiles => #{channel => D}}},
        contracts => #{{receive_audio,Peer,<<"music">>} => #{id => binary:copy(<<"C">>,32),revision => 1}},
        suspended => false,resume_after => 100,catalogs => #{},poll_at => erlang:monotonic_time(millisecond)+10000},
    try Fun(S,Id) after
        exit(Control,kill),unregister_if_present(ba_swarm_control),
        case Old of undefined -> application:unset_env(ba_core,audio_clock_adapter);{ok,V} -> application:set_env(ba_core,audio_clock_adapter,V) end
    end.
unregister_if_present(Name) -> case whereis(Name) of undefined -> ok;_ -> unregister(Name) end.
