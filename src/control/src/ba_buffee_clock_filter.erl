%% Bounded median of measured UTC-minus-monotonic offsets. No timers or I/O.
-module(ba_buffee_clock_filter).
-export([new/1, add/2, count/1, estimate/1]).

new(Size) when is_integer(Size), Size > 0 -> #{size => Size,samples => []}.
add(Sample, #{size := Size,samples := Samples} = Filter) ->
    Filter#{samples := lists:sublist([Sample | Samples],Size)}.
count(#{samples := Samples}) -> length(Samples).
estimate(#{size := Size,samples := Samples}) when length(Samples) =:= Size ->
    Sorted = lists:sort([maps:get(offset_ns,S) || S <- Samples]),
    Middle = Size div 2,
    Offset = case Size rem 2 of
        0 -> (lists:nth(Middle,Sorted)+lists:nth(Middle+1,Sorted)) div 2;
        1 -> lists:nth(Middle+1,Sorted)
    end,
    {ok,Offset};
estimate(_) -> {error,warming_up}.
