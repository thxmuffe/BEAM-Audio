%% Admission envelope helpers: OTP Ed25519, JSON, URI and secure randomness.
%% No custom encryption: credentials travel inside the WebRTC DTLS connection.
-module(parvi_cluster_auth).
-export([fresh/1, sign/2, read/1, verify/2, invitation/1, parse_invitation/1,
         valid_name/1, binding/1]).

fresh(Bytes) -> binary:encode_hex(crypto:strong_rand_bytes(Bytes)).
sign(Body, Private) ->
    Data = iolist_to_binary(json:encode(Body)),
    Signature = crypto:sign(eddsa, none, [<<"parvi-otp-admission/v1:">>, Data], [Private, ed25519]),
    #{<<"body">> => base64:encode(Data), <<"signature">> => binary:encode_hex(Signature)}.
read(#{<<"body">> := B, <<"signature">> := Signature}) when byte_size(B) =< 32768 ->
    Data = base64:decode(B),
    #{<<"type">> := _} = Body = json:decode(Data),
    {Body, Data, binary:decode_hex(Signature)}.
verify(Envelope, Public) ->
    {Body, Data, Signature} = read(Envelope),
    true = byte_size(Public) =:= 64 andalso byte_size(Signature) =:= 64,
    Public = binary:encode_hex(binary:decode_hex(Public)),
    true = crypto:verify(eddsa, none, [<<"parvi-otp-admission/v1:">>, Data], Signature,
                         [binary:decode_hex(Public), ed25519]),
    Body.

invitation(Fields) ->
    Pairs = [{K, case V of N when is_integer(N) -> integer_to_binary(N); _ -> V end}
             || {K, V} <- maps:to_list(Fields)],
    <<"parvi://cluster/v1?", (uri_string:compose_query(Pairs))/binary>>.
parse_invitation(Link) when is_binary(Link), byte_size(Link) =< 2048 ->
    try
        #{scheme := <<"parvi">>, host := <<"cluster">>, path := <<"/v1">>, query := Q} =
            URI = uri_string:parse(string:trim(Link)),
        4 = map_size(URI),
        Pairs = uri_string:dissect_query(Q), 7 = length(Pairs),
        F = maps:from_list(Pairs), 7 = map_size(F),
        [<<"cluster">>, <<"expires">>, <<"invite">>, <<"issuer">>, <<"node">>, <<"secret">>, <<"v">>] = lists:sort(maps:keys(F)),
        <<"1">> = maps:get(<<"v">>, F),
        [true = hex(maps:get(K, F), N) || {K, N} <- [{<<"cluster">>, 32}, {<<"invite">>, 32},
            {<<"issuer">>, 64}, {<<"secret">>, 64}]],
        true = valid_name(maps:get(<<"node">>, F)),
        Expires = binary_to_integer(maps:get(<<"expires">>, F)),
        true = Expires > erlang:system_time(second),
        {ok, F#{<<"expires">> := Expires}}
    catch _:_ -> {error, invalid_invitation} end;
parse_invitation(_) -> {error, invalid_invitation}.
hex(B, N) when is_binary(B), byte_size(B) =:= N ->
    re:run(B, <<"^[0-9A-F]+$">>, [{capture, none}]) =:= match;
hex(_, _) -> false.
valid_name(N) when is_binary(N), byte_size(N) =< 128 ->
    re:run(N, <<"^[A-Za-z0-9_-]+@[A-Za-z0-9_.:-]+$">>, [{capture, none}]) =:= match;
valid_name(_) -> false.

binding(PC) ->
    Module = 'Elixir.ExWebRTC.PeerConnection',
    Fingerprints = [fingerprint(Module:get_local_description(PC)),
                    fingerprint(Module:get_remote_description(PC))],
    binary:encode_hex(crypto:hash(sha256, json:encode(lists:sort(Fingerprints)))).
fingerprint(#{sdp := Text}) ->
    {ok, SDP} = 'Elixir.ExSDP':parse(Text),
    Attrs = lists:append(['Elixir.ExSDP':get_attributes(S, fingerprint)
                         || S <- [SDP | maps:get(media, SDP)]]),
    [{fingerprint, {Algorithm, Value}}] = lists:usort(Attrs),
    [atom_to_binary(Algorithm), Value].
