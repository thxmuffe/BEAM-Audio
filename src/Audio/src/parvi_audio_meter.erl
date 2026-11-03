%% Initial sample interpretation and metering stay in BEAM, before optimisation.
-module(parvi_audio_meter).
-export([new/0, accumulate/3, levels/1]).

new() -> {0.0, 0.0, 0}.
accumulate(_, <<>>, Acc) -> Acc;
accumulate(float32_le, <<V:32/little-float, Rest/binary>>, Acc) ->
    accumulate(float32_le, Rest, add(V, Acc));
%% Non-finite IEEE samples do not match an Erlang float segment.
accumulate(float32_le, <<_:32, Rest/binary>>, Acc) ->
    accumulate(float32_le, Rest, add(0.0, Acc));
accumulate(pcm16_le, <<V:16/little-signed, Rest/binary>>, Acc) ->
    accumulate(pcm16_le, Rest, add(V / 32768.0, Acc));
accumulate(pcm24_le, <<V:24/little-signed, Rest/binary>>, Acc) ->
    accumulate(pcm24_le, Rest, add(V / 8388608.0, Acc));
accumulate(pcm32_le, <<V:32/little-signed, Rest/binary>>, Acc) ->
    accumulate(pcm32_le, Rest, add(V / 2147483648.0, Acc)).

add(V, {Peak, Squares, Count}) -> {max(Peak, abs(V)), Squares + V * V, Count + 1}.
levels({Peak, Squares, Count}) ->
    RMS = case Count of 0 -> 0.0; _ -> math:sqrt(Squares / Count) end,
    #{<<"peak_db">> => db(Peak), <<"rms_db">> => db(RMS)}.
db(Value) -> 20 * math:log10(max(Value, math:pow(10, -96 / 20))).
