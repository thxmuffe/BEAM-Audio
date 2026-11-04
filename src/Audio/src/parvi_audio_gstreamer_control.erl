%% Pure receiver policy. A sink-clock target is not calibrated speaker emission.
-module(parvi_audio_gstreamer_control).
-export([target/3, correction/2]).

target(#{continuous := true, presentation := #{clock_timeline := Timeline} = Schedule,
         segment_start_position := Start} = Source,
       #{rtp_timestamp := RTP}, #{timeline := Timeline} = Reference) ->
    %% A master owns this reference even when offline members make coverage
    %% partial. Followers need an acquired mapping; coverage is not admission.
    case clock_ready(Reference) of
        false -> {error,source_or_receiver_clock_unavailable};
        true -> target_position(Source,Schedule,Start,RTP)
    end;
target(_,_,_) -> {error,source_or_receiver_clock_unavailable}.
clock_ready(#{role := master}) -> true;
clock_ready(#{state := synchronized}) -> true;
clock_ready(#{role := follower,filter_ready := true,state := holdover}) -> true;
clock_ready(_) -> false.
target_position(Source,Schedule,Start,RTP) ->
    case parvi_audio_gstreamer_schedule:source_position(Source,RTP,0) of
        {ok,Position} when Position >= Start ->
            {ok,Schedule#{sample_position => Position,
                target_output_time_ns => parvi_audio_presentation:target(Schedule,Position)}};
        {ok,_} -> {error,previous_capture_segment};
        Error -> Error
    end.

%% Correct small phase errors with a slow clock servo; large changes relock.
%% Positive offset error means output must be later, so slow the reference.
correction(Desired,Applied) when abs(Desired-Applied) > 20000000 -> relock;
correction(Desired,Applied) ->
    PPM = max(-50.0,min(50.0,-(Desired-Applied)/10000)),
    #{correction_ppm => PPM,max_absolute_ppm => 50}.
