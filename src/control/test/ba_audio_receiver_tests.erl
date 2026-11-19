-module(ba_audio_receiver_tests).
-include_lib("eunit/include/eunit.hrl").

same_contract_is_a_noop_and_stale_revision_is_rejected_test() ->
    Peer = binary:copy(<<"A">>,64),Id = binary:copy(<<"B">>,32),Key = {receive_audio,Peer,<<"music">>},
    S = #{contracts => #{Key => #{id => Id,revision => 2}},subscriptions => retained_media_and_buffers},
    ?assertEqual({reply,ok,S},ba_audio_receiver:handle_call({contract,receive_audio,Peer,<<"music">>,Id,2},undefined,S)),
    ?assertEqual({reply,{error,stale_contract},S},ba_audio_receiver:handle_call({contract,receive_audio,Peer,<<"music">>,Id,1},undefined,S)).

%% Native AAC is the only transport: catalogue offers must name it.
only_native_offers_are_accepted_test() ->
    Base = #{<<"kind">> => <<"catalog.offer">>,<<"source">> => <<"music">>,<<"incarnation">> => binary:copy(<<"A">>,32),
        <<"name">> => <<"Music">>,<<"paused">> => false,<<"rate">> => 48000,<<"channels">> => 2,
        <<"format">> => <<"float32_le">>,<<"clock">> => <<"clock">>},
    ?assertEqual(ok,ba_audio_stream_protocol:validate(Base#{<<"transport">> => <<"gst_aac_rtp_v2">>})),
    ?assertError(_,ba_audio_stream_protocol:validate(Base)),
    ?assertError(_,ba_audio_stream_protocol:validate(Base#{<<"transport">> => <<"pcm">>,<<"format">> => <<"opus">>})).
