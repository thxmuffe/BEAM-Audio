-module(ba_audio_catalog_events_tests).
-include_lib("eunit/include/eunit.hrl").

idle_ticks_do_not_query_peers_test() ->
    fixture(fun(S,_,_) ->
        %% Even a stale former polling deadline must not cause network reads.
        lists:foldl(fun(_,Acc) -> {noreply,Next}=ba_audio_receiver:handle_info(tick,Acc),Next end,
                    S#{poll_at => 0},lists:seq(1,24)),
        no_message()
    end).

%% Dark Sessions: a listener discovers nothing. It reads a catalogue when an ON
%% AIR Device announces one, and re-reads only sources it already knows.
listener_reads_only_announced_or_known_sources_test() ->
    fixture(fun(S,[A,B],Contexts) ->
        {noreply,Started}=ba_audio_receiver:handle_info(catalog_bootstrap,S),no_message(),
        {noreply,_}=ba_audio_receiver:handle_info({audio_session_up,maps:get(A,Contexts)},Started),no_message(),
        Announced=deliver(A,id(),#{<<"kind">> => <<"catalog.changed">>},Contexts,Started),
        [{A,Read,#{<<"kind">> := <<"catalog.read">>}}]=messages(1),
        Done=deliver(A,Read,#{<<"kind">> => <<"catalog.end">>},Contexts,Announced),no_message(),
        Listening=Done#{subscriptions := #{id() => #{intent => #{device => B}}}},
        {reply,ok,_}=ba_audio_receiver:handle_call(refresh,undefined,Listening),
        ?assertMatch([{B,_,#{<<"kind">> := <<"catalog.read">>}}],messages(1)),no_message()
    end).

notifications_during_read_are_coalesced_test() ->
    fixture(fun(S,[A|_],Contexts) ->
        Changed=#{<<"kind">> => <<"catalog.changed">>},
        First=deliver(A,id(),Changed,Contexts,S),
        [{A,Read,_}]=messages(1),
        Dirty=lists:foldl(fun(_,Acc) -> deliver(A,id(),Changed,Contexts,Acc) end,First,lists:seq(1,8)),
        no_message(),
        Next=deliver(A,Read,#{<<"kind">> => <<"catalog.end">>},Contexts,Dirty),
        [{A,Read2,#{<<"kind">> := <<"catalog.read">>}}]=messages(1),
        Done=deliver(A,Read2,#{<<"kind">> => <<"catalog.end">>},Contexts,Next),
        ?assertEqual(#{},maps:get(catalogs,Done)),no_message()
    end).

publication_lifecycle_announces_changes_test() ->
    fixture(fun(S,_,_) ->
        Offer=#{source_key => <<"music">>,incarnation => id(),name => <<"Music">>,paused => false,
            profiles => #{channel => #{encoding => pcm,sample_rate => 48000,channel_count => 2,sample_format => float32_le,
                clock => <<"test">>,stream_handler => native_gst_aac}}},
        Source=spawn(fun Loop() -> receive {'$gen_call',From,describe} -> gen_server:reply(From,Offer),Loop() end end),
        try
            {reply,ok,Registered}=ba_audio_receiver:handle_call({register,Source},undefined,S),
            announcements(2),
            {noreply,Paused}=ba_audio_receiver:handle_info({publication_state,Source,true},Registered),
            announcements(2),
            {noreply,_}=ba_audio_receiver:handle_info({publication_state,Source,true},Paused),no_message(),
            ReboundOffer=Offer#{incarnation := id()},
            {noreply,Rebound}=ba_audio_receiver:handle_info({publication_rebound,Source,ReboundOffer},Paused),
            announcements(2),
            #{monitor := Ref}=maps:get(<<"music">>,maps:get(sources,Rebound)),
            {noreply,Removed}=ba_audio_receiver:handle_info({'DOWN',Ref,process,Source,normal},Rebound),
            ?assertEqual(#{},maps:get(sources,Removed)),announcements(2),no_message()
        after exit(Source,kill) end
    end).

changed_notification_has_exact_wire_shape_test() ->
    ?assertEqual(ok,ba_audio_stream_protocol:validate(#{<<"kind">> => <<"catalog.changed">>})),
    ?assertException(error,_,ba_audio_stream_protocol:validate(#{<<"kind">> => <<"catalog.changed">>,<<"extra">> => true})).

deliver(Peer,Id,Payload,Contexts,S) ->
    {noreply,Next}=ba_audio_receiver:handle_info({buffee_audio,maps:get(Peer,Contexts),Id,Payload},S),Next.
announcements(N) ->
    [?assertMatch({_,_,#{<<"kind">> := <<"catalog.changed">>}},M) || M <- messages(N)].
messages(N) -> [receive {sent,P,Id,Payload} -> {P,Id,Payload} after 1000 -> error(missing_message) end || _ <- lists:seq(1,N)].
no_message() -> receive {sent,_,_,_}=M -> error({unexpected_network_message,M}) after 0 -> ok end.
id() -> binary:encode_hex(crypto:strong_rand_bytes(16)).
fixture(F) ->
    A=binary:copy(<<"A">>,64),B=binary:copy(<<"B">>,64),Peers=[A,B],Parent=self(),
    Contexts=maps:from_list([{P,#{peer => P,session => id(),buffee => id(),deadline => erlang:monotonic_time(millisecond)+30000}} || P <- Peers]),
    %% This Device holds on_air, the privilege a publication needs.
    Seed=lists:duplicate(64,$E),{Pub,_}=crypto:generate_key(eddsa,ed25519,binary:decode_hex(list_to_binary(Seed))),
    View=#{policy => #{peers => maps:from_list([{P,[stream_read]} || P <- Peers])},
           device_privileges => #{binary:encode_hex(Pub) => [ba_session_privileges:wire(on_air)]}},
    Control=spawn(fun Loop() -> receive
        {'$gen_call',From,{audio_context,P}} -> gen_server:reply(From,{ok,maps:get(P,Contexts)}),Loop();
        {'$gen_call',From,{audio_message,P,Id,Payload}} ->
            ok=ba_audio_stream_protocol:validate(Payload),Parent ! {sent,P,Id,Payload},gen_server:reply(From,ok),Loop()
    end end),
    Membership=spawn(fun Loop() -> receive {'$gen_call',From,current} -> gen_server:reply(From,{ok,View}),Loop() end end),
    true=register(ba_buffee_control,Control),true=register(ba_buffee_membership,Membership),
    StateDir=os:getenv("BA_STATE_DIR"),os:unsetenv("BA_STATE_DIR"),
    OldSeed=os:getenv("BA_IDENTITY_SEED"),os:putenv("BA_IDENTITY_SEED",Seed),
    S=#{sources => #{},offers => #{},subscriptions => #{},providers => #{},catalogs => #{},contracts => #{},
        control => Control,suspended => false,resume_after => undefined,rejected => 0},
    try F(S,Peers,Contexts) after
        unregister(ba_buffee_control),unregister(ba_buffee_membership),exit(Control,kill),exit(Membership,kill),
        case StateDir of false -> ok;_ -> os:putenv("BA_STATE_DIR",StateDir) end,
        case OldSeed of false -> os:unsetenv("BA_IDENTITY_SEED");_ -> os:putenv("BA_IDENTITY_SEED",OldSeed) end
    end.
