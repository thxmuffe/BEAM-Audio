%% Source-owned presentation schedule. No media buffering or native execution.
-module(parvi_audio_presentation).
-export([stamp/4, target/2, output_deadline/2]).

%% Keep a fixed sample/time anchor within a capture segment and clock timeline.
%% Packet-send jitter and later clock slews must not independently retime packets.
stamp(#{continuous := true, estimated_capture_time_ns := Capture,
        sample_position := Position, sample_rate := Rate, capture_segment := Segment} = Header,
      Delay, Timeline, State)
        when is_integer(Capture), is_integer(Delay), Delay >= 0, Rate > 0,
             is_binary(Timeline) ->
    Key = {Segment,Timeline,Delay,Rate},
    Next = case maps:get(key,State,undefined) of
        Key -> State;
        _ -> State#{key => Key, revision => maps:get(revision,State,0)+1,
                    position => Position, time => Capture+Delay}
    end,
    Target = maps:get(time,Next)+(Position-maps:get(position,Next))*1000000000 div Rate,
    Schedule = #{stream_id => maps:get(stream_id,State), revision => maps:get(revision,Next),
                 clock_timeline => Timeline, target_output_time_ns => parvi_audio_rtp_time:quantize(Target),
                 sample_position => Position, sample_rate => Rate, delay_ns => Delay,
                 basis => nominal_capture},
    {Header#{presentation => Schedule},Next};
stamp(Header,_,_,State) ->
    %% A missing capture/reference starts a new schedule when measurements return.
    {maps:remove(presentation,Header),maps:remove(key,State)}.

%% Resolve a sample position against an identified presentation anchor.
target(#{target_output_time_ns := Time,sample_position := Anchor,sample_rate := Rate},Position)
        when is_integer(Time), is_integer(Position), Rate > 0 ->
    Time+(Position-Anchor)*1000000000 div Rate.

%% Calibrated delay must describe the path from the chosen handoff boundary to
%% speaker emission. An OS route-latency report alone is not that calibration.
%% Return a local monotonic deadline; native output must still execute it.
output_deadline(Target,CalibratedDelay)
        when is_integer(Target), is_integer(CalibratedDelay), CalibratedDelay >= 0 ->
    parvi_clock:to_monotonic(Target-CalibratedDelay).
