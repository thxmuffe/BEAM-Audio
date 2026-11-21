-module(ba_session_board_tests).
-include_lib("eunit/include/eunit.hrl").

device() -> {P,K}=crypto:generate_key(eddsa,ed25519),{binary:encode_hex(P),K}.
setup() ->
    Session=binary:copy(<<"A">>,32),{Inv,InvKey}=ba_session_passport:invitation_key(binary:copy(<<"5">>,32)),
    {Holder,HK}=device(),{Asker,AK}=device(),
    P=#{<<"members">> => #{Holder => #{<<"permissions">> => [<<"owner">>]}}},
    Ctx=#{session => Session,invitation => Inv,policy => P},
    {Session,InvKey,Ctx,P,{Holder,HK},{Asker,AK}}.

request_spreads_and_closes_by_decline_or_grant_test() ->
    {Session,InvKey,Ctx,P,{Holder,HK},{Asker,AK}}=setup(),
    Join=ba_session_passport:join(Session,Asker,InvKey),
    {Id,Packet}=ba_session_board:request(Session,Asker,Join,<<"stream_publish">>,AK),
    {[Id],B1}=ba_session_board:merge(#{Id => Packet},Ctx,ba_session_board:new()),
    ?assertEqual(#{Asker => [<<"stream_publish">>]},ba_session_board:open(B1,P)),
    %% Merging the same entry again (from another neighbour) changes nothing.
    ?assertEqual({[],B1},ba_session_board:merge(#{Id => Packet},Ctx,B1)),
    %% A grant closes it: the Device now holds the privilege.
    Granted=P#{<<"members">> := (maps:get(<<"members">>,P))#{Asker => #{<<"permissions">> => [<<"stream_publish">>]}}},
    ?assertEqual(#{},ba_session_board:open(B1,Granted)),
    %% A grant holder's decline closes it on every copy that receives it.
    {D,DP}=ba_session_board:decline(Session,Holder,Id,Asker,<<"stream_publish">>,HK),
    {[D],B2}=ba_session_board:merge(#{D => DP},Ctx,B1),
    ?assertEqual(#{},ba_session_board:open(B2,P)),
    ?assertEqual([],ba_session_board:open_ids(B2,P,Asker,<<"stream_publish">>)),
    ?assertEqual(2,map_size(ba_session_board:entries(B2))),
    ?assertEqual(#{},ba_session_board:expire(B2,erlang:system_time(second)+86401)).

forged_entries_are_dropped_test() ->
    {Session,InvKey,Ctx,_,{Holder,_},{Asker,AK}}=setup(),
    %% No valid join certificate: not a Session Device.
    {Bad,BadPacket}=ba_session_board:request(Session,Asker,binary:copy(<<"0">>,128),<<"stream_publish">>,AK),
    ?assertEqual({[],#{}},ba_session_board:merge(#{Bad => BadPacket},Ctx,#{})),
    %% A decline from someone without grant is ignored.
    Join=ba_session_passport:join(Session,Asker,InvKey),
    {Id,Packet}=ba_session_board:request(Session,Asker,Join,<<"stream_publish">>,AK),
    {Fake,FakePacket}=ba_session_board:decline(Session,Asker,Id,Asker,<<"stream_publish">>,AK),
    {[Id],B}=ba_session_board:merge(#{Id => Packet,Fake => FakePacket},Ctx,#{}),
    ?assertEqual([Id],ba_session_board:open_ids(B,maps:get(policy,Ctx),Asker,<<"stream_publish">>)),
    %% An entry stored under another ID, or from another Session, is refused.
    {Other,_}=ba_session_board:request(Session,Asker,Join,<<"stream_publish">>,AK),
    ?assertEqual({[],#{}},ba_session_board:merge(#{Other => Packet},Ctx,#{})),
    ?assertEqual({[],#{}},ba_session_board:merge(#{Id => Packet},Ctx#{session := binary:copy(<<"B">>,32)},#{})),
    _ = Holder.

%% Session messages are sealed end to end with a key from the link secret.
envelope_round_trip_and_session_binding_test() ->
    Key=ba_session_passport:envelope_key(binary:copy(<<"5">>,32)),
    Sealed=ba_session_passport:seal_envelope(Key,<<"S1">>,<<"hello">>),
    ?assertEqual(<<"hello">>,ba_session_passport:open_envelope(Key,<<"S1">>,Sealed)),
    ?assertError(_,ba_session_passport:open_envelope(Key,<<"S2">>,Sealed)),
    Other=ba_session_passport:envelope_key(binary:copy(<<"6">>,32)),
    ?assertError(_,ba_session_passport:open_envelope(Other,<<"S1">>,Sealed)).

%% A gossiped note is checked on every hop: signature, join certificate, age.
gossip_note_test() ->
    {Session,InvKey,Ctx,_,_,{Asker,AK}}=setup(),
    Join=ba_session_passport:join(Session,Asker,InvKey),
    {Id,Packet}=ba_session_gossip:note(Session,Asker,Join,<<"on_air">>,#{},AK),
    ?assertMatch({ok,#{<<"author">> := Asker,<<"kind">> := <<"on_air">>}},ba_session_gossip:check(Id,Packet,Ctx)),
    ?assertEqual(error,ba_session_gossip:check(Id,Packet,Ctx#{session := binary:copy(<<"B">>,32)})),
    {Bad,BadPacket}=ba_session_gossip:note(Session,Asker,binary:copy(<<"0">>,128),<<"on_air">>,#{},AK),
    ?assertEqual(error,ba_session_gossip:check(Bad,BadPacket,Ctx)).

playback_and_response_gossip_are_signed_and_validated_test() ->
    {Session,InvKey,Ctx,_,_,{Asker,AK}}=setup(),
    Join=ba_session_passport:join(Session,Asker,InvKey),
    Batch=#{<<"count">> => 5,<<"sum_ns">> => 123456789},
    {Id,Packet}=ba_session_gossip:note(Session,Asker,Join,<<"response">>,Batch,AK),
    ?assertMatch({ok,#{<<"count">> := 5,<<"sum_ns">> := 123456789}},ba_session_gossip:check(Id,Packet,Ctx)),
    ?assertError(function_clause,ba_session_gossip:note(Session,Asker,Join,<<"response">>,Batch#{<<"count">> := 0},AK)),
    Playback=#{<<"playing">> => true,<<"failed">> => false,<<"started">> => true,<<"revision">> => 1},
    {PId,PlaybackPacket}=ba_session_gossip:note(Session,Asker,Join,<<"playback">>,Playback,AK),
    ?assertMatch({ok,#{<<"playing">> := true,<<"started">> := true}},ba_session_gossip:check(PId,PlaybackPacket,Ctx)),
    ?assertError(function_clause,ba_session_gossip:note(Session,Asker,Join,<<"playback">>,Playback#{<<"playing">> := false},AK)).

%% A granted request stays answered even after the privilege is taken back.
granted_request_stays_closed_test() ->
    {Session,InvKey,Ctx,P,{Holder,HK},{Asker,AK}}=setup(),
    Join=ba_session_passport:join(Session,Asker,InvKey),
    {Id,Packet}=ba_session_board:request(Session,Asker,Join,<<"stream_publish">>,AK),
    {G,GP}=ba_session_board:granted(Session,Holder,Id,Asker,<<"stream_publish">>,HK),
    {_,B}=ba_session_board:merge(#{Id => Packet,G => GP},Ctx,#{}),
    ?assertEqual(#{},ba_session_board:open(B,P)).
