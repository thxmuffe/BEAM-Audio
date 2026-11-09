%% Interpret Core Audio metadata/raw planes in Erlang; never resample or requantize.
-module(ba_core_audio).
-export([format/1, samples/2, host_ns/2]).

format(<<Rate:64/little-float, 16#6c70636d:32/little, Flags:32/little,
         PacketBytes:32/little, 1:32/little, FrameBytes:32/little,
         Channels:32/little, Bits:32/little, Numer:32/little, Denom:32/little>>)
        when Channels > 0, Numer > 0, Denom > 0 ->
    true = Rate > 0 andalso Rate =:= float(round(Rate)),
    true = Flags band 2 =:= 0 andalso Flags band 8 =/= 0,
    Encoding = case {Flags band 1, Flags band 4, Bits} of
        {1, _, 32} -> float32_le;
        {0, 4, 16} -> pcm16_le;
        {0, 4, 24} -> pcm24_le;
        {0, 4, 32} -> pcm32_le
    end,
    Bytes = Bits div 8, Planar = Flags band 32 =/= 0,
    Expected = case Planar of true -> Bytes; false -> Bytes * Channels end,
    true = FrameBytes =:= Expected andalso PacketBytes =:= Expected,
    #{rate => round(Rate), channels => Channels, encoding => Encoding,
      sample_bytes => Bytes, frame_bytes => Bytes * Channels, planar => Planar,
      timebase_numer => Numer, timebase_denom => Denom}.

host_ns(Ticks, #{timebase_numer := N, timebase_denom := D}) -> Ticks * N div D.

samples(<<Count:32/little, Data/binary>>, #{channels := Channels, planar := Planar,
                                        sample_bytes := Bytes, frame_bytes := Frame}) ->
    {Buffers, <<>>} = buffers(Count, Data, []),
    PCM = case {Planar, Buffers} of
        {false, [{Channels, Interleaved}]} -> Interleaved;
        {true, _} ->
            true = length(Buffers) =:= Channels,
            [{1, First} | _] = Buffers, Size = byte_size(First),
            true = Size rem Bytes =:= 0,
            true = lists:all(fun({C, B}) -> C =:= 1 andalso byte_size(B) =:= Size end, Buffers),
            iolist_to_binary(lists:reverse(interleave([B || {_, B} <- Buffers], Bytes, [])))
    end,
    true = byte_size(PCM) rem Frame =:= 0,
    {PCM, byte_size(PCM) div Frame}.

buffers(0, Rest, Acc) -> {lists:reverse(Acc), Rest};
buffers(N, <<Channels:32/little, Size:32/little, PCM:Size/binary, Rest/binary>>, Acc) ->
    buffers(N - 1, Rest, [{Channels, PCM} | Acc]).
interleave([<<>> | _], _, Acc) -> Acc;
interleave(Planes, Bytes, Acc) ->
    {Heads, Tails} = lists:unzip([begin <<H:Bytes/binary, T/binary>> = P, {H, T} end || P <- Planes]),
    interleave(Tails, Bytes, [Heads | Acc]).
