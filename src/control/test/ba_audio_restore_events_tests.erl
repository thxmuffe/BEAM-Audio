-module(ba_audio_restore_events_tests).
-include_lib("eunit/include/eunit.hrl").
-export([status/0,resync/1]).
status() -> get(test_clock).
resync(Reason) -> put(test_resync,Reason),ok.
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

reception_ready_shortens_the_retry_after_failed_signaling_test() ->
    fixture(fun(S,Id) ->
        put(test_clock,#{state => synchronized,filter_ready => true,last_sync => 101,age_ns => 0}),
        whereis(ba_session_control) ! {test_send_result,{error,unavailable}},
        {noreply,Waiting}=ba_audio_receiver:handle_info(tick,S),
        receive {attempt,Id,#{<<"kind">> := <<"subscribe">>}} -> ok after 1000 -> error(no_attempt) end,
        ?assertMatch(#{Id := #{state := waiting_for_source,error := signaling_unavailable}},maps:get(subscriptions,Waiting)),
        {noreply,_}=ba_audio_receiver:handle_info(tick,Waiting),no_attempt(),
        whereis(ba_session_control) ! {test_send_result,ok},
        {noreply,Ready}=ba_audio_receiver:handle_info(audio_signaling_ready,Waiting),
        {noreply,Opening}=ba_audio_receiver:handle_info(tick,Ready),
        receive {attempt,Id,#{<<"kind">> := <<"subscribe">>}} -> ok after 1000 -> error(no_attempt) end,
        ?assertMatch(#{Id := #{state := opening}},maps:get(subscriptions,Opening))
    end).

network_hints_preserve_clock_acquisition_and_live_media_test() ->
    fixture(fun(S,Id) ->
        R=maps:get(Id,maps:get(subscriptions,S)),I=maps:get(intent,R),Peer=maps:get(device,I),
        Media=spawn(fun() -> receive stop -> ok end end),
        Membership=spawn(fun Loop() -> receive {'$gen_call',From,current} ->
            gen_server:reply(From,{ok,#{policy => #{peers => #{Peer => []}}}}),Loop() end end),
        true=register(ba_session_membership,Membership),
        try
            lists:foreach(fun(State) ->
                Clock=#{state => State,filter_ready => State=:=synchronized,filter_sample_count => 14,last_sync => 101,age_ns => 0},
                put(test_clock,Clock),erase(test_resync),
                Live=R#{media := Media,state := active,mix_ready => true},
                Before=S#{subscriptions := #{Id => Live},providers => #{}},
                After=lists:foldl(fun(_,Acc) ->
                    {noreply,Next}=ba_audio_receiver:handle_cast(network_changed,Acc),Next
                end,Before,lists:seq(1,3)),
                ?assertEqual(Clock,status()),?assertEqual(undefined,get(test_resync)),
                ?assertEqual(maps:remove(poll_at,Before),maps:remove(poll_at,After)),
                ?assert(is_process_alive(Media)),no_attempt(),
                {noreply,_}=ba_audio_receiver:handle_info(tick,After),
                receive {attempt,_,#{<<"kind">> := <<"catalog.read">>}} -> ok
                    after 1000 -> error(no_discovery_refresh) end,
                ?assert(is_process_alive(Media)),no_attempt()
            end,[acquiring,synchronized])
        after
            Media ! stop,exit(Membership,kill),unregister_if_present(ba_session_membership),
            erase(test_clock),erase(test_resync)
        end
    end).

fixture(Fun) ->
    I = ba_subscription_tests:intent(<<"music">>),Id = maps:get(id,I),Peer = maps:get(device,I),
    Context = #{peer => Peer,link => binary:copy(<<"D">>,32),session => maps:get(session,I),deadline => erlang:monotonic_time(millisecond)+10000},
    Parent = self(),Control = spawn(fun() -> (fun Loop(Result) -> receive
        {'$gen_call',From,{audio_context,_}} -> gen_server:reply(From,{ok,Context}),Loop(Result);
        {'$gen_call',From,{audio_message,_,Request,P}} -> Parent ! {attempt,Request,P},gen_server:reply(From,Result),Loop(Result);
        {test_send_result,Next} -> Loop(Next)
    end end)(ok) end),true = register(ba_session_control,Control),
    Old = application:get_env(ba_core,audio_clock_adapter),application:set_env(ba_core,audio_clock_adapter,?MODULE),
    R = #{intent => I,state => waiting_for_source,media => undefined,retry_at => erlang:monotonic_time(millisecond)-1,packets => 0},
    D = #{encoding => pcm,sample_rate => 48000,sample_format => float32_le,channel_count => 2,clock => <<"test">>,stream_handler => engine_flac},
    %% Any existing file stands in for the engine executable.
    OldPort = os:getenv("BA_AUDIO_ENGINE"),os:putenv("BA_AUDIO_ENGINE",code:which(?MODULE)),
    S = #{subscriptions => #{Id => R},offers => #{{Peer,<<"music">>} => #{incarnation => binary:copy(<<"E">>,32),profiles => #{channel => D}}},
        contracts => #{{receive_audio,Peer,<<"music">>} => #{id => binary:copy(<<"C">>,32),revision => 1}},
        suspended => false,resume_after => 100,sources => #{},providers => #{},
        catalogs => #{},poll_at => erlang:monotonic_time(millisecond)+10000},
    try Fun(S,Id) after
        exit(Control,kill),unregister_if_present(ba_session_control),
        case OldPort of false -> os:unsetenv("BA_AUDIO_ENGINE");_ -> os:putenv("BA_AUDIO_ENGINE",OldPort) end,
        case Old of undefined -> application:unset_env(ba_core,audio_clock_adapter);{ok,V} -> application:set_env(ba_core,audio_clock_adapter,V) end
    end.
unregister_if_present(Name) -> case whereis(Name) of undefined -> ok;_ -> unregister(Name) end.
