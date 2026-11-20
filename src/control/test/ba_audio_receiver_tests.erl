-module(ba_audio_receiver_tests).
-include_lib("eunit/include/eunit.hrl").

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
    ?assertEqual(ok,ba_audio_stream_protocol:validate(Base#{<<"transport">> => <<"engine_flac_srtp_v1">>})),
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
    Endpoint=Base#{<<"kind">> => <<"signal.endpoint">>,<<"public">> => Public,<<"hosts">> => <<"192.168.1.5">>,<<"port">> => 40000},
    ?assertEqual(ok,ba_audio_stream_protocol:validate(Endpoint)),
    ?assertError(_,ba_audio_stream_protocol:validate(Endpoint#{<<"port">> => 0})),
    Stream=Base#{<<"kind">> => <<"signal.stream">>,<<"public">> => Public,<<"wrapped">> => binary:encode_hex(crypto:strong_rand_bytes(46)),
        <<"ssrc">> => 1234,<<"rate">> => 48000,<<"anchor_ns">> => <<"1795190853785180625">>},
    ?assertEqual(ok,ba_audio_stream_protocol:validate(Stream)),
    ?assertError(_,ba_audio_stream_protocol:validate(Stream#{<<"key">> => <<"plain">>})),
    ?assertError(_,ba_audio_stream_protocol:validate(Stream#{<<"anchor_ns">> => <<"soon">>})).
