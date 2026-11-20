%% Exact, flat control messages; PCM/encoded audio never enter Desk envelopes.
-module(ba_audio_stream_protocol).
-export([validate/1,offer/3,descriptor/1,addresses/1]).
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
        %% Receiver -> provider: its ephemeral X25519 key and the addresses its
        %% engine can be reached at (local and public, see addresses/1).
        <<"signal.endpoint">> ->
            ba_session_passport:exact(P,base()++[<<"public">>,<<"addresses">>]),media(P),
            true = ba_hex:valid(maps:get(<<"public">>,P),64),
            _ = addresses(maps:get(<<"addresses">>,P));
        %% Provider -> receiver: its ephemeral key, the stream key wrapped for this
        %% receiver, and where the stream sits on the Session timeline. Keys never
        %% travel in the clear: the Reception can read these payloads.
        %% Its addresses let the receiver punch through its own NAT towards it.
        <<"signal.stream">> ->
            ba_session_passport:exact(P,base()++[<<"public">>,<<"wrapped">>,<<"ssrc">>,<<"rate">>,<<"anchor_ns">>,<<"addresses">>]),media(P),
            _ = addresses(maps:get(<<"addresses">>,P)),
            true = ba_hex:valid(maps:get(<<"public">>,P),64),
            true = ba_hex:valid(maps:get(<<"wrapped">>,P),92),
            Ssrc = maps:get(<<"ssrc">>,P),true = is_integer(Ssrc) andalso Ssrc>=0 andalso Ssrc<16#100000000,
            true = lists:member(maps:get(<<"rate">>,P),[44100,48000]),
            Anchor = maps:get(<<"anchor_ns">>,P),text(Anchor,20),_ = binary_to_integer(Anchor)
    end,ok.
base() -> [<<"kind">>,<<"source">>,<<"incarnation">>,<<"attempt">>].
%% 1-8 space-separated "ip/port" pairs (signed control has no arrays):
%% <<"192.168.1.5/40000 91.145.90.96/40000">> -> [[<<"192.168.1.5">>,40000],...]
addresses(Text) ->
    text(Text,600),
    Pairs = binary:split(Text,<<" ">>,[global]),
    true = length(Pairs)>=1 andalso length(Pairs)=<8,
    [begin
        [Host,PortText] = binary:split(Pair,<<"/">>),
        {ok,_} = inet:parse_strict_address(binary_to_list(Host)),
        Port = binary_to_integer(PortText),true = Port>0 andalso Port<65536,
        [Host,Port]
     end || Pair <- Pairs].
media(P) -> identity(P),true = ba_hex:valid(maps:get(<<"attempt">>,P),32).
identity(P) -> text(maps:get(<<"source">>,P),128),true = ba_hex:valid(maps:get(<<"incarnation">>,P),32),ok.
text(B,N) -> true = is_binary(B) andalso byte_size(B)>0 andalso byte_size(B)=<N,ok.
offer(Key,Inc,#{name := Name,paused := Paused,profiles := #{channel := D}}) ->
    P = #{<<"kind">> => <<"catalog.offer">>,<<"source">> => Key,<<"incarnation">> => Inc,
          <<"name">> => Name,<<"paused">> => Paused,<<"rate">> => maps:get(sample_rate,D),
          <<"channels">> => maps:get(channel_count,D),<<"format">> => atom_to_binary(maps:get(sample_format,D)),
          <<"clock">> => maps:get(clock,D)},
    engine_flac = maps:get(stream_handler,D),
    Native = P#{<<"transport">> => <<"engine_flac_srtp_v1">>},ok=validate(Native),Native.
descriptor(#{<<"transport">> := <<"engine_flac_srtp_v1">>,<<"rate">> := R,<<"channels">> := 2,
        <<"format">> := <<"float32_le">>,<<"clock">> := Clock}) when R=:=44100;R=:=48000 ->
    text(Clock,128),#{encoding => pcm,sample_format => float32_le,sample_rate => R,channel_count => 2,
        clock => Clock,stream_handler => engine_flac};
descriptor(_) -> error(unsupported_transport).
