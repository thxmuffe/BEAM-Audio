-module(parvi_audio_meter_tests).
-include_lib("eunit/include/eunit.hrl").

silence_test() ->
    ?assertEqual(#{<<"peak_db">> => -96.0, <<"rms_db">> => -96.0},
        parvi_audio_meter:levels(parvi_audio_meter:new())).

peak_and_rms_are_distinct_test() ->
    M = parvi_audio_meter:levels(parvi_audio_meter:accumulate(float32_le,
        <<0.5:32/little-float, 0.0:32/little-float>>, parvi_audio_meter:new())),
    ?assert(abs(maps:get(<<"peak_db">>,M) - (-6.020599913)) < 0.00001),
    ?assert(abs(maps:get(<<"rms_db">>,M) - (-9.030899870)) < 0.00001).

above_full_scale_is_not_hidden_test() ->
    M = parvi_audio_meter:levels(parvi_audio_meter:accumulate(float32_le,
        <<-1.25:32/little-float>>, parvi_audio_meter:new())),
    ?assert(maps:get(<<"peak_db">>,M) > 0).
