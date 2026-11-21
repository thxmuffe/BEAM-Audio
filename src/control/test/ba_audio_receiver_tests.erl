-module(ba_audio_receiver_tests).
-include_lib("eunit/include/eunit.hrl").

%% A dead provider must release its attempt instead of rejecting every fresh
%% receiver subscription after a lost close/endpoint during a network change.
%% Late failure events from an older ICE connection must leave its replacement.
failed_ice_ends_only_the_current_attempt_test() ->
    S=#{conn => 42,role => provider,open => true,path => direct},
    Event=fun(C) -> {ba_audio_engine,self(),#{event => <<"ice_state">>,conn => C,state => <<"failed">>}} end,
    ?assertEqual({noreply,S},ba_engine_media_session:handle_info(Event(41),S)),
    {stop,Reason,Closed}=ba_engine_media_session:handle_info(Event(42),S),
    ?assertEqual({shutdown,ice_failed},Reason),
    ?assertEqual(ice_failed,ba_diagnostics:reason(Reason)),
    ?assertEqual(failed,maps:get(path,Closed)),
    ?assertEqual(1,maps:get(ice_failures,Closed)).

same_contract_is_a_noop_and_stale_revision_is_rejected_test() ->
    Peer = binary:copy(<<"A">>,64),Id = binary:copy(<<"B">>,32),Key = {receive_audio,Peer,<<"music">>},
    S = #{contracts => #{Key => #{id => Id,revision => 2}},subscriptions => retained_media_and_buffers},
    ?assertEqual({reply,ok,S},ba_audio_receiver:handle_call({contract,receive_audio,Peer,<<"music">>,Id,2},undefined,S)),
    ?assertEqual({reply,{error,stale_contract},S},ba_audio_receiver:handle_call({contract,receive_audio,Peer,<<"music">>,Id,1},undefined,S)).

%% The native engine is the only transport: catalogue offers must name it.
only_engine_offers_are_accepted_test() ->
    Base = #{<<"kind">> => <<"catalog.offer">>,<<"source">> => <<"music">>,<<"incarnation">> => binary:copy(<<"A">>,32),
        <<"name">> => <<"Music">>,<<"paused">> => false,<<"rate">> => 48000,<<"channels">> => 2,
        <<"format">> => <<"float32_le">>,<<"clock">> => <<"clock">>},
    Profile = <<"engine_flac_srtp_v2">>,
    ?assertMatch(#{wire_profile := Profile},ba_stream_handler_engine:info()),
    ?assertEqual(ok,ba_audio_stream_protocol:validate(Base#{<<"transport">> => Profile})),
    Descriptor=#{sample_rate => 48000,channel_count => 2,sample_format => float32_le,
        clock => <<"clock">>,stream_handler => engine_flac},
    ?assertEqual(Base#{<<"transport">> => Profile},
        ba_audio_stream_protocol:offer(<<"music">>,binary:copy(<<"A">>,32),
            #{name => <<"Music">>,paused => false,profiles => #{channel => Descriptor}})),
    ?assertError(unsupported_transport,ba_audio_stream_protocol:validate(Base#{<<"transport">> => <<"engine_flac_srtp_v1">>})),
    ?assertError(_,ba_audio_stream_protocol:validate(Base#{<<"transport">> => <<"gst_aac_rtp_v2">>})),
    ?assertError(_,ba_audio_stream_protocol:validate(Base)),
    ?assertError(_,ba_audio_stream_protocol:validate(Base#{<<"transport">> => <<"pcm">>,<<"format">> => <<"opus">>})).

%% The stream key reaches only the receiver holding the matching X25519 key,
%% for this attempt only.
stream_key_wraps_for_one_receiver_and_attempt_test() ->
    {ProviderPublic,ProviderPrivate}=crypto:generate_key(ecdh,x25519),
    {ReceiverPublic,ReceiverPrivate}=crypto:generate_key(ecdh,x25519),
    {_,OtherPrivate}=crypto:generate_key(ecdh,x25519),
    Key=crypto:strong_rand_bytes(30),Attempt=binary:copy(<<"A">>,32),
    Wrapped=ba_engine_media_session:wrap(Key,crypto:compute_key(ecdh,ReceiverPublic,ProviderPrivate,x25519),Attempt),
    ?assertEqual(46,byte_size(Wrapped)),
    ?assertEqual(Key,ba_engine_media_session:unwrap(Wrapped,crypto:compute_key(ecdh,ProviderPublic,ReceiverPrivate,x25519),Attempt)),
    ?assertError(stream_key_unwrap_failed,
        ba_engine_media_session:unwrap(Wrapped,crypto:compute_key(ecdh,ProviderPublic,OtherPrivate,x25519),Attempt)),
    ?assertError(stream_key_unwrap_failed,
        ba_engine_media_session:unwrap(Wrapped,crypto:compute_key(ecdh,ProviderPublic,ReceiverPrivate,x25519),binary:copy(<<"B">>,32))).

engine_signals_are_validated_test() ->
    Base=#{<<"source">> => <<"music">>,<<"incarnation">> => binary:copy(<<"A">>,32),<<"attempt">> => binary:copy(<<"B">>,32)},
    Public=binary:encode_hex(crypto:strong_rand_bytes(32)),
    Ice = <<"a=ice-ufrag:abcd\r\na=ice-pwd:0123456789abcdefghijkl\r\na=candidate:1 1 UDP 2122317823 192.168.1.5 40000 typ host\r\n">>,
    Endpoint=Base#{<<"kind">> => <<"signal.endpoint">>,<<"public">> => Public,<<"ice">> => Ice},
    ?assertEqual(ok,ba_audio_stream_protocol:validate(Endpoint)),
    ?assertError(_,ba_audio_stream_protocol:validate(Endpoint#{<<"ice">> => <<"no credentials">>})),
    Stream=Base#{<<"kind">> => <<"signal.stream">>,<<"public">> => Public,<<"wrapped">> => binary:encode_hex(crypto:strong_rand_bytes(46)),
        <<"ssrc">> => 1234,<<"rate">> => 48000,<<"anchor_ns">> => <<"1795190853785180625">>,
        <<"ice">> => Ice,<<"packet_index">> => 65540},
    ?assertEqual(ok,ba_audio_stream_protocol:validate(Stream)),
    ?assertError(_,ba_audio_stream_protocol:validate(Stream#{<<"key">> => <<"plain">>})),
    ?assertError(_,ba_audio_stream_protocol:validate(Stream#{<<"anchor_ns">> => <<"soon">>})),
    ?assertError(_,ba_audio_stream_protocol:validate(maps:remove(<<"packet_index">>,Stream))),
    [?assertError(_,ba_audio_stream_protocol:validate(Stream#{<<"packet_index">> := Bad})) || Bad <- [-1,16#1000000000000]].
