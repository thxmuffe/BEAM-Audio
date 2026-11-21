-module(ba_audio_catalog_events_tests).
-include_lib("eunit/include/eunit.hrl").

publication_supplies_the_offer_and_withdrawal_supersedes_older_gossip_test() ->
    fixture(fun(S,Peer) ->
        Key= <<"microphone">>,Wire=wire(Key),
        {noreply,Live}=ba_audio_receiver:handle_info({publication,Peer,publication(Key,1,Wire)},S),
        ?assertMatch(#{offers := #{{Peer,Key} := #{name := <<"Input">>,profiles := #{channel := _}}}},Live),
        {noreply,Off}=ba_audio_receiver:handle_info({publication,Peer,publication(Key,2,null)},Live),
        ?assertEqual(#{},maps:get(offers,Off)),
        ?assertEqual({noreply,Off},ba_audio_receiver:handle_info({publication,Peer,publication(Key,1,Wire)},Off))
    end).

system_publication_requires_on_air_but_a_microphone_does_not_test() ->
    fixture(fun(S,Peer) ->
        Key= <<"default-output">>,
        {noreply,Rejected}=ba_audio_receiver:handle_info({publication,Peer,publication(Key,1,wire(Key))},S),
        ?assertEqual(#{},maps:get(offers,Rejected)),
        Mic= <<"microphone">>,
        {noreply,Added}=ba_audio_receiver:handle_info({publication,Peer,publication(Mic,2,wire(Mic))},Rejected),
        ?assert(maps:is_key({Peer,Mic},maps:get(offers,Added)))
    end).

publication_lifecycle_gossips_descriptor_and_withdrawal_test() ->
    fixture(fun(S,_) ->
        Key= <<"default-output">>,Offer=offer(Key),
        Source=spawn(fun Loop() -> receive {'$gen_call',From,describe} -> gen_server:reply(From,Offer),Loop() end end),
        try
            {reply,ok,Registered}=ba_audio_receiver:handle_call({register,Source},undefined,S),
            #{<<"revision">> := First,<<"offer">> := #{<<"source">> := Key},<<"refresh_levels">> := true}=announcement(),
            {noreply,Paused}=ba_audio_receiver:handle_info({publication_state,Source,true},Registered),
            #{<<"offer">> := #{<<"paused">> := true},<<"refresh_levels">> := false}=announcement(),
            {noreply,_}=ba_audio_receiver:handle_info({publication_state,Source,true},Paused),
            #{monitor := Ref}=maps:get(Key,maps:get(sources,Paused)),
            {noreply,Removed}=ba_audio_receiver:handle_info({'DOWN',Ref,process,Source,normal},Paused),
            #{<<"revision">> := Last,<<"offer">> := null}=announcement(),
            ?assert(Last>First),?assertEqual(#{},maps:get(sources,Removed))
        after exit(Source,kill) end
    end).

publication(Key,Revision,Wire) ->
    #{<<"source">> => Key,<<"revision">> => Revision,<<"offer">> => Wire,<<"refresh_levels">> => false}.
wire(Key) ->
    Offer=offer(Key),ba_audio_stream_protocol:offer(Key,maps:get(incarnation,Offer),Offer).
offer(Key) ->
    #{source_key => Key,incarnation => binary:encode_hex(crypto:strong_rand_bytes(16)),
      name => <<"Input">>,paused => false,
      profiles => #{channel => #{encoding => pcm,sample_rate => 48000,channel_count => 2,
        sample_format => float32_le,clock => <<"test">>,stream_handler => engine_flac}}}.
announcement() -> receive {publication,Fields} -> Fields after 1000 -> error(no_publication) end.

new_attempt_replaces_only_the_same_authorized_subscription_test() ->
    fixture(fun(S,[Peer|_],Contexts) ->
        {ok,OldMedia}=gen_event:start(),
        {ok,NewMedia}=gen_event:start(),
        Source=spawn(fun Loop() ->
            receive {'$gen_call',From,{attach,NewMedia}} -> gen_server:reply(From,ok),Loop() end
        end),
        Runtime=start_stub(ba_session_runtime_sup,NewMedia),
        Audio=start_stub(ba_audio_sup,NewMedia),
        try
            Context=maps:get(Peer,Contexts),Id=id(),Key=<<"music">>,Inc=id(),Contract=id(),
            ProviderKey={Peer,maps:get(link,Context),Id},
            OldAttempt=id(),NewAttempt=id(),
            Old=#{source => Key,incarnation => Inc,attempt => OldAttempt,context => Context,
                  subscription => Id,paused => false,media => OldMedia,monitor => monitor(process,OldMedia)},
            Descriptor=#{stream_handler => engine_flac},
            Entry=#{pid => Source,offer => #{incarnation => Inc,paused => false,profiles => #{channel => Descriptor}}},
            Before=S#{providers := #{ProviderKey => Old},sources := #{Key => Entry},
                contracts := #{{publish,Peer,Key} => #{id => Contract,revision => 2}}},
            Subscribe=#{<<"kind">> => <<"subscribe">>,<<"source">> => Key,<<"incarnation">> => Inc,
                        <<"attempt">> => OldAttempt,<<"contract">> => Contract,<<"revision">> => 2},
            ?assertEqual(Before,deliver(Peer,Id,Subscribe,Contexts,Before)),
            ?assertMatch([{Peer,Id,#{<<"kind">> := <<"accepted">>,<<"attempt">> := OldAttempt}}],messages(1)),
            Replacement=Subscribe#{<<"attempt">> := NewAttempt},
            ?assertEqual(Before,deliver(Peer,Id,Replacement#{<<"revision">> := 1},Contexts,Before)),
            ?assertMatch([{Peer,Id,#{<<"kind">> := <<"rejected">>,<<"reason">> := <<"contract">>}}],messages(1)),
            ?assert(is_process_alive(OldMedia)),
            After=deliver(Peer,Id,Replacement,Contexts,Before),
            ?assertMatch(#{ProviderKey := #{attempt := NewAttempt,media := NewMedia}},maps:get(providers,After)),
            ?assertNot(is_process_alive(OldMedia)),
            ?assertMatch([{Peer,Id,#{<<"kind">> := <<"accepted">>,<<"attempt">> := NewAttempt}}],messages(1)),
            Close=#{<<"kind">> => <<"close">>,<<"source">> => Key,<<"incarnation">> => Inc,<<"attempt">> => OldAttempt},
            LateClose=deliver(Peer,Id,Close,Contexts,After),
            ?assertEqual(maps:get(providers,After),maps:get(providers,LateClose)),
            ?assert(is_process_alive(NewMedia)),no_message()
        after
            unregister(ba_session_runtime_sup),unregister(ba_audio_sup),
            [exit(Pid,kill) || Pid <- [Runtime,Audio,Source,OldMedia,NewMedia]]
        end
    end).

start_stub(Name,Media) ->
    Pid=spawn(fun Loop() ->
        receive {'$gen_call',From,{start_child,_}} -> gen_server:reply(From,{ok,Media}),Loop() end
    end),
    true=register(Name,Pid),Pid.

deliver(Peer,Id,Payload,Contexts,S) ->
    {noreply,Next}=ba_audio_receiver:handle_info({session_audio,maps:get(Peer,Contexts),Id,Payload},S),Next.
announcements(N) ->
    [?assertMatch({_,_,#{<<"kind">> := <<"catalog.changed">>}},M) || M <- messages(N)].
messages(N) -> [receive {sent,P,Id,Payload} -> {P,Id,Payload} after 1000 -> error(missing_message) end || _ <- lists:seq(1,N)].
no_message() -> receive {sent,_,_,_}=M -> error({unexpected_network_message,M}) after 0 -> ok end.
id() -> binary:encode_hex(crypto:strong_rand_bytes(16)).
fixture(F) ->
    Peer=binary:copy(<<"A">>,64),Parent=self(),
    OldSeed=os:getenv("BA_IDENTITY_SEED"),os:putenv("BA_IDENTITY_SEED",lists:duplicate(64,$E)),
    {Pub,_}=ba_device_store:identity(),
    View=#{device_privileges => #{binary:encode_hex(Pub) => [ba_session_privileges:wire(on_air)]}},
    Membership=spawn(fun Loop() -> receive
        {'$gen_call',From,current} -> gen_server:reply(From,{ok,View}),Loop();
        {'$gen_cast',{announce,_,<<"publication">>,Fields}} -> Parent ! {publication,Fields},Loop()
    end end),
    true=register(ba_session_membership,Membership),
    S=#{sources => #{},offers => #{},subscriptions => #{},providers => #{},publication_versions => #{},contracts => #{}},
    try F(S,Peer) after
        unregister(ba_session_membership),exit(Membership,kill),
        case OldSeed of false -> os:unsetenv("BA_IDENTITY_SEED");_ -> os:putenv("BA_IDENTITY_SEED",OldSeed) end
    end.
