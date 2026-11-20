%% Exact, flat control messages; PCM/encoded audio never enter Desk envelopes.
-module(ba_audio_stream_protocol).
-export([validate/1,offer/3,descriptor/1]).
validate(#{<<"kind">> := K} = P) ->
    case K of
        <<"catalog.read">> -> exact(P,[<<"kind">>]);
        <<"catalog.changed">> -> exact(P,[<<"kind">>]);
        <<"catalog.end">> -> exact(P,[<<"kind">>]);
        <<"catalog.offer">> ->
            exact(P,[<<"kind">>,<<"source">>,<<"incarnation">>,<<"name">>,<<"rate">>,<<"channels">>,<<"format">>,<<"clock">>,<<"paused">>,<<"transport">>]),
            identity(P),text(maps:get(<<"name">>,P),128),
            true = is_boolean(maps:get(<<"paused">>,P)),_ = descriptor(P);
        <<"subscribe">> ->
            exact(P,base()++[<<"contract">>,<<"revision">>]),media(P),
            true = ba_hex:valid(maps:get(<<"contract">>,P),32),
            N = maps:get(<<"revision">>,P),true = is_integer(N) andalso N>0 andalso N=<9007199254740991;
        <<"accepted">> -> exact(P,base()++[<<"paused">>]),media(P),true = is_boolean(maps:get(<<"paused">>,P));
        <<"state">> -> exact(P,base()++[<<"paused">>]),media(P),true = is_boolean(maps:get(<<"paused">>,P));
        <<"rejected">> ->
            exact(P,base()++[<<"reason">>]),media(P),
            true = lists:member(maps:get(<<"reason">>,P),[<<"contract">>,<<"unavailable">>,<<"capacity">>,<<"transport">>]);
        <<"close">> -> exact(P,base()),media(P);
        _ when K =:= <<"signal.offer">>; K =:= <<"signal.answer">> ->
            exact(P,base()++[<<"sdp">>]),media(P),text(maps:get(<<"sdp">>,P),12000),
            %% DTLS certificate fingerprint travels inside the authenticated SDP.
            true = binary:match(maps:get(<<"sdp">>,P),<<"a=fingerprint:sha-256 ">>) =/= nomatch;
        <<"signal.candidate">> ->
            exact(P,base()++[<<"candidate">>,<<"mid">>,<<"line">>]),media(P),
            %% Empty is the standard end-of-candidates marker, not an error.
            Candidate=maps:get(<<"candidate">>,P),true=is_binary(Candidate) andalso byte_size(Candidate)=<1024,
            text(maps:get(<<"mid">>,P),64),
            N = maps:get(<<"line">>,P),true = is_integer(N) andalso N>=0 andalso N=<16
    end,ok.
base() -> [<<"kind">>,<<"source">>,<<"incarnation">>,<<"attempt">>].
media(P) -> identity(P),true = ba_hex:valid(maps:get(<<"attempt">>,P),32).
identity(P) -> text(maps:get(<<"source">>,P),128),true = ba_hex:valid(maps:get(<<"incarnation">>,P),32),ok.
exact(P,K) -> ba_buffee_passport:exact(P,K).
text(B,N) -> true = is_binary(B) andalso byte_size(B)>0 andalso byte_size(B)=<N,ok.
offer(Key,Inc,#{name := Name,paused := Paused,profiles := #{channel := D}}) ->
    P = #{<<"kind">> => <<"catalog.offer">>,<<"source">> => Key,<<"incarnation">> => Inc,
          <<"name">> => Name,<<"paused">> => Paused,<<"rate">> => maps:get(sample_rate,D),
          <<"channels">> => maps:get(channel_count,D),<<"format">> => atom_to_binary(maps:get(sample_format,D)),
          <<"clock">> => maps:get(clock,D)},
    native_gst_aac = maps:get(stream_handler,D),
    Native = P#{<<"transport">> => <<"gst_aac_rtp_v2">>},ok=validate(Native),Native.
descriptor(#{<<"transport">> := <<"gst_aac_rtp_v2">>,<<"rate">> := R,<<"channels">> := 2,
        <<"format">> := <<"float32_le">>,<<"clock">> := Clock}) when R=:=44100;R=:=48000 ->
    text(Clock,128),#{encoding => pcm,sample_format => float32_le,sample_rate => R,channel_count => 2,
        clock => Clock,stream_handler => native_gst_aac};
descriptor(_) -> error(unsupported_transport).
