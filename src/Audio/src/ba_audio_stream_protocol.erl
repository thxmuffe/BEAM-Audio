%% Exact, flat control messages; PCM/encoded audio never enter Desk envelopes.
-module(ba_audio_stream_protocol).
-export([validate/1,offer/3,descriptor/1,identity/1]).
validate(#{<<"kind">> := K} = P) ->
    case K of
        <<"catalog.read">> -> exact(P,[<<"kind">>]);
        <<"catalog.end">> -> exact(P,[<<"kind">>]);
        <<"catalog.offer">> ->
            exact(P,[<<"kind">>,<<"source">>,<<"incarnation">>,<<"name">>,<<"rate">>,<<"channels">>,<<"format">>,<<"clock">>,<<"paused">>]),
            identity(P),text(maps:get(<<"name">>,P),128),
            true = is_boolean(maps:get(<<"paused">>,P)),_ = descriptor(P);
        <<"subscribe">> ->
            exact(P,base()++[<<"contract">>,<<"revision">>]),session(P),
            true = ba_buffee_job:hex(maps:get(<<"contract">>,P),32),
            N = maps:get(<<"revision">>,P),true = is_integer(N) andalso N>0 andalso N=<9007199254740991;
        <<"accepted">> -> exact(P,base()++[<<"paused">>]),session(P),true = is_boolean(maps:get(<<"paused">>,P));
        <<"state">> -> exact(P,base()++[<<"paused">>]),session(P),true = is_boolean(maps:get(<<"paused">>,P));
        <<"rejected">> ->
            exact(P,base()++[<<"reason">>]),session(P),
            true = lists:member(maps:get(<<"reason">>,P),[<<"contract">>,<<"unavailable">>,<<"capacity">>,<<"transport">>]);
        <<"close">> -> exact(P,base()),session(P);
        _ when K =:= <<"signal.offer">>; K =:= <<"signal.answer">> ->
            exact(P,base()++[<<"sdp">>]),session(P),text(maps:get(<<"sdp">>,P),12000),
            %% DTLS certificate fingerprint travels inside the authenticated SDP.
            true = binary:match(maps:get(<<"sdp">>,P),<<"a=fingerprint:sha-256 ">>) =/= nomatch;
        <<"signal.candidate">> ->
            exact(P,base()++[<<"candidate">>,<<"mid">>,<<"line">>]),session(P),
            text(maps:get(<<"candidate">>,P),1024),text(maps:get(<<"mid">>,P),64),
            N = maps:get(<<"line">>,P),true = is_integer(N) andalso N>=0 andalso N=<16
    end,ok.
base() -> [<<"kind">>,<<"source">>,<<"incarnation">>,<<"attempt">>].
session(P) -> identity(P),true = ba_buffee_job:hex(maps:get(<<"attempt">>,P),32).
identity(P) -> text(maps:get(<<"source">>,P),128),true = ba_buffee_job:hex(maps:get(<<"incarnation">>,P),32),ok.
exact(P,K) -> ba_buffee_passport:exact(P,K).
text(B,N) -> true = is_binary(B) andalso byte_size(B)>0 andalso byte_size(B)=<N,ok.
offer(Key,Inc,#{name := Name,paused := Paused,profiles := #{channel := D}}) ->
    P = #{<<"kind">> => <<"catalog.offer">>,<<"source">> => Key,<<"incarnation">> => Inc,
          <<"name">> => Name,<<"paused">> => Paused,<<"rate">> => maps:get(sample_rate,D),
          <<"channels">> => maps:get(channel_count,D),<<"format">> => atom_to_binary(maps:get(sample_format,D)),
          <<"clock">> => maps:get(clock,D)},ok = validate(P),P.
descriptor(#{<<"rate">> := Rate,<<"channels">> := Channels,<<"format">> := F,<<"clock">> := Clock}) ->
    true = is_integer(Rate) andalso Rate>=8000 andalso Rate=<192000,
    true = Channels=:=1 orelse Channels=:=2,text(Clock,128),
    case F of
        <<"opus">> ->
            48000 = Rate,2 = Channels,
            #{encoding => opus,sample_format => opus,sample_rate => Rate,channel_count => Channels,clock => Clock,
              stream_handler => webrtc_audio_opus,rtp_timestamp_semantics => global_playback_48k_v1};
        _ -> Format = case F of <<"float32_le">> -> float32_le;<<"pcm16_le">> -> pcm16_le;
        <<"pcm24_le">> -> pcm24_le;<<"pcm32_le">> -> pcm32_le end,
    #{encoding => pcm,sample_format => Format,sample_rate => Rate,channel_count => Channels,clock => Clock}
    end.
