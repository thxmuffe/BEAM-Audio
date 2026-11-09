%% Pure receiver policy. A sink-clock target is not calibrated speaker emission.
-module(parvi_audio_gstreamer_control).
-export([target/3]).

target(#{rtp_timestamp_semantics := global_playback_48k_v1,presentation_stream_id := Stream},
       #{rtp_timestamp := RTP,generation := Generation},
       #{timeline := Timeline,filtered_utc_time := Now} = Reference) ->
    case clock_ready(Reference) of
        false -> {error,source_or_receiver_clock_unavailable};
        true ->
            case parvi_audio_rtp_time:decode(RTP,Now) of
                {ok,Target} -> {ok,#{stream_id => Stream,revision => Generation,
                    clock_timeline => Timeline,sample_position => RTP,sample_rate => 48000,
                    target_output_time_ns => Target,basis => packet_global_playback_target}};
                Error -> Error
            end
    end;
target(_,_,_) -> {error,packet_target_clock_unavailable}.
clock_ready(#{state := synchronized}) -> true;
clock_ready(_) -> false.
