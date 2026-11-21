%% Exact, flat control messages; PCM/encoded audio never enter Desk envelopes.
-module(ba_audio_stream_protocol).
-export([validate/1,offer/3,descriptor/1,wire_profile/0]).
-define(WIRE_PROFILE,<<"engine_flac_srtp_v2">>).

wire_profile() -> ?WIRE_PROFILE.
validate(#{<<"kind">> := K} = P) ->
    case K of
        <<"catalog.read">> -> ba_session_passport:exact(P,[<<"kind">>]);
        <<"catalog.changed">> -> ba_session_passport:exact(P,[<<"kind">>]);
        <<"catalog.end">> -> ba_session_passport:exact(P,[<<"kind">>]);
        <<"catalog.offer">> ->
            ba_session_passport:exact(P,[<<"kind">>,<<"source">>,<<"incarnation">>,<<"name">>,<<"rate">>,<<"channels">>,<<"format">>,<<"clock">>,<<"paused">>,<<"transport">>]),
            identity(P),text(maps:get(<<"name">>,P),128),
            true = is_boolean(maps:get(<<"paused">>,P)),_ = descriptor(P);
        <<"subscribe">> ->
            ba_session_passport:exact(P,base()++[<<"contract">>,<<"revision">>]),media(P),
            true = ba_hex:valid(maps:get(<<"contract">>,P),32),
            N = maps:get(<<"revision">>,P),true = is_integer(N) andalso N>0 andalso N=<9007199254740991;
        <<"accepted">> -> ba_session_passport:exact(P,base()++[<<"paused">>]),media(P),true = is_boolean(maps:get(<<"paused">>,P));
        <<"state">> -> ba_session_passport:exact(P,base()++[<<"paused">>]),media(P),true = is_boolean(maps:get(<<"paused">>,P));
        <<"rejected">> ->
            ba_session_passport:exact(P,base()++[<<"reason">>]),media(P),
            true = lists:member(maps:get(<<"reason">>,P),[<<"contract">>,<<"unavailable">>,<<"capacity">>,<<"transport">>]);
        <<"close">> -> ba_session_passport:exact(P,base()),media(P);
        %% Receiver -> provider: its ephemeral X25519 key and the ICE
        %% description of its engine connection (credentials and candidates).
        <<"signal.endpoint">> ->
            ba_session_passport:exact(P,base()++[<<"public">>,<<"ice">>]),media(P),
            true = ba_hex:valid(maps:get(<<"public">>,P),64),
            ice(maps:get(<<"ice">>,P));
        %% Provider -> receiver: its ephemeral key, the stream key wrapped for this
        %% receiver, and where the stream sits on the Session timeline. Keys never
        %% travel in the clear: the Reception can read these payloads.
        %% With the provider's own ICE description.
        <<"signal.stream">> ->
            ba_session_passport:exact(P,base()++[<<"public">>,<<"wrapped">>,<<"ssrc">>,<<"rate">>,<<"anchor_ns">>,<<"packet_index">>,<<"ice">>]),media(P),
            ice(maps:get(<<"ice">>,P)),
            true = ba_hex:valid(maps:get(<<"public">>,P),64),
            true = ba_hex:valid(maps:get(<<"wrapped">>,P),92),
            Ssrc = maps:get(<<"ssrc">>,P),true = is_integer(Ssrc) andalso Ssrc>=0 andalso Ssrc<16#100000000,
            Index=maps:get(<<"packet_index">>,P),true=is_integer(Index) andalso Index>=0 andalso Index<16#1000000000000,
            true = lists:member(maps:get(<<"rate">>,P),[44100,48000]),
            Anchor = maps:get(<<"anchor_ns">>,P),text(Anchor,20),_ = binary_to_integer(Anchor)
    end,ok.
base() -> [<<"kind">>,<<"source">>,<<"incarnation">>,<<"attempt">>].
%% An ICE description as libjuice writes it (SDP lines: credentials and
%% candidates). Bounded; libjuice parses it in the engine.
ice(Text) ->
    text(Text,4000),
    true = binary:match(Text,<<"a=ice-ufrag:">>)=/=nomatch andalso binary:match(Text,<<"a=ice-pwd:">>)=/=nomatch,ok.
media(P) -> identity(P),true = ba_hex:valid(maps:get(<<"attempt">>,P),32).
identity(P) -> text(maps:get(<<"source">>,P),128),true = ba_hex:valid(maps:get(<<"incarnation">>,P),32),ok.
text(B,N) -> true = is_binary(B) andalso byte_size(B)>0 andalso byte_size(B)=<N,ok.
offer(Key,Inc,#{name := Name,paused := Paused,profiles := #{channel := D}}) ->
    P = #{<<"kind">> => <<"catalog.offer">>,<<"source">> => Key,<<"incarnation">> => Inc,
          <<"name">> => Name,<<"paused">> => Paused,<<"rate">> => maps:get(sample_rate,D),
          <<"channels">> => maps:get(channel_count,D),<<"format">> => atom_to_binary(maps:get(sample_format,D)),
          <<"clock">> => maps:get(clock,D)},
    engine_flac = maps:get(stream_handler,D),
    Native = P#{<<"transport">> => ?WIRE_PROFILE},ok=validate(Native),Native.
descriptor(#{<<"transport">> := ?WIRE_PROFILE,<<"rate">> := R,<<"channels">> := 2,
        <<"format">> := <<"float32_le">>,<<"clock">> := Clock}) when R=:=44100;R=:=48000 ->
    text(Clock,128),#{encoding => pcm,sample_format => float32_le,sample_rate => R,channel_count => 2,
        clock => Clock,stream_handler => engine_flac};
descriptor(_) -> error(unsupported_transport).
