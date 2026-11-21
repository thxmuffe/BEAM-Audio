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
