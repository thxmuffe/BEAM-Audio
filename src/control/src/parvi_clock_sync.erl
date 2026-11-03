%% Four-timestamp measurement and bounded correction policy, independent of OTP I/O.
-module(parvi_clock_sync).
-export([measure/4, correct/5]).

measure(T1,T2,T3,T4) when T3 >= T2, T4 >= T1 ->
    Delay = (T4-T1)-(T3-T2),
    case Delay >= 0 of
        true -> {ok,#{offset_ns => ((T2-T1)+(T3-T4)) div 2,
                      sampled_at => T4,round_trip_ns => Delay}};
        false -> {error,invalid_peer_timestamps}
    end;
measure(_,_,_,_) -> {error,invalid_peer_timestamps}.

correct(undefined,T,Target,_,_) -> {parvi_clock_mapping:new(T,Target),0,true};
correct(Mapping,T,Target,Threshold,PPM) ->
    Error = Target-parvi_clock_mapping:offset(Mapping,T),
    case abs(Error) > Threshold of
        true -> {parvi_clock_mapping:correct(Mapping,T,Target,PPM),Error,true};
        false -> {Mapping,Error,false}
    end.
