%% Version 1: descriptor-selected layout; PCM stays in its source format.
-module(parvi_audio_packet).
-export([validate_descriptor/2, validate_block/4, encode/4, decode/3, selected/3,
         frame_bytes/1, max_payload_bytes/1]).
-define(MAX_PACKET, 16384).

validate_descriptor(channel, D) -> validate_pcm(D);
validate_descriptor(point, #{coordinate_frame := Frame} = D)
        when is_binary(Frame), byte_size(Frame) > 0 -> validate_pcm(D);
validate_descriptor(_, _) -> {error, unsupported_descriptor}.

validate_pcm(#{encoding := pcm, sample_format := Format, sample_rate := Rate,
                      channel_count := Channels, clock := Clock} = D)
        when is_integer(Rate), Rate > 0, is_integer(Channels), Channels > 0,
             is_binary(Clock), byte_size(Clock) > 0 ->
    case bytes_per_sample(Format) =/= error andalso
         maps:get(packet_version, D, 1) =:= 1 andalso
         maps:get(time_unit, D, nanosecond) =:= nanosecond of
        true -> ok;
        false -> {error, unsupported_descriptor}
    end;
validate_pcm(_) -> {error, unsupported_descriptor}.

%% Validate without constructing/copying the full packet at publication time.
validate_block(Profile, D, H, PCM) ->
    case checked_prefix(Profile, D, H, PCM) of
        {ok, _} -> ok;
        Error -> Error
    end.

encode(Profile, D, #{playback_time := Time, sequence := Seq} = H, PCM) ->
    case checked_prefix(Profile, D, H, PCM) of
        {ok, Prefix} -> {ok, <<Time:64/signed, Seq:32, Prefix/binary, PCM/binary>>};
        Error -> Error
    end;
encode(_, _, _, _) -> {error, invalid_packet}.

checked_prefix(Profile, D, #{playback_time := Time, sequence := Seq} = H, PCM)
        when is_integer(Time), Time >= -9223372036854775808, Time < 9223372036854775808,
             is_integer(Seq), Seq >= 0, Seq < 4294967296, is_binary(PCM) ->
    try
        Prefix = prefix(Profile, H),
        true = 12 + byte_size(Prefix) + byte_size(PCM) =< ?MAX_PACKET,
        {ok, _} = frames(D, PCM),
        {ok, Prefix}
    catch _:_ -> {error, invalid_packet} end;
checked_prefix(_, _, _, _) -> {error, invalid_packet}.

prefix(channel, #{channel_id := Id}) when is_integer(Id), Id >= 0, Id < 4294967296 ->
    <<Id:32>>;
prefix(point, #{x := X, y := Y, z := Z}) when is_number(X), is_number(Y), is_number(Z) ->
    <<X:64/float, Y:64/float, Z:64/float>>.

decode(Profile, D, <<Time:64/signed, Seq:32, Rest/binary>> = Packet)
        when byte_size(Packet) =< ?MAX_PACKET ->
    try
        {H, PCM} = unpack(Profile, Rest),
        {ok, Frames} = frames(D, PCM),
        {ok, H#{playback_time => Time, sequence => Seq, frame_count => Frames}, PCM}
    catch _:_ -> {error, invalid_packet} end;
decode(_, _, _) -> {error, invalid_packet}.

unpack(channel, <<Id:32, PCM/binary>>) -> {#{channel_id => Id}, PCM};
unpack(point, <<X:64/float, Y:64/float, Z:64/float, PCM/binary>>) ->
    {#{x => X, y => Y, z => Z}, PCM}.

frames(Descriptor, PCM) ->
    Size = frame_bytes(Descriptor),
    true = byte_size(PCM) > 0 andalso byte_size(PCM) rem Size =:= 0,
    {ok, byte_size(PCM) div Size}.
frame_bytes(#{sample_format := Format, channel_count := Channels}) ->
    bytes_per_sample(Format) * Channels.
max_payload_bytes(channel) -> ?MAX_PACKET - 16;
max_payload_bytes(point) -> ?MAX_PACKET - 36.
bytes_per_sample(float32_le) -> 4;
bytes_per_sample(pcm16_le) -> 2;
bytes_per_sample(pcm24_le) -> 3;
bytes_per_sample(pcm32_le) -> 4;
bytes_per_sample(_) -> error.

selected(_, all, _) -> true;
selected(channel, #{channels := Channels}, #{channel_id := Id}) -> lists:member(Id, Channels);
selected(point, #{x := X, y := Y, z := Z, radius := R}, #{x := PX, y := PY, z := PZ}) ->
    (PX-X)*(PX-X) + (PY-Y)*(PY-Y) + (PZ-Z)*(PZ-Z) =< R*R.
