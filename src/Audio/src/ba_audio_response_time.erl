%% Measurements and bounded advice only. Packet targets are never rewritten.
-module(ba_audio_response_time).
-export([add/3,summary/1,increase/2,text/1]).

add(Late,#{revision := Revision,offset_ms := Offset}=Policy,S0)
        when is_integer(Revision),is_integer(Offset) ->
    S=case maps:get(policy,S0,undefined) of
        {Revision,Offset} -> S0;
        _ -> #{policy => {Revision,Offset},count => 0,samples => 0,total_ns => 0,
               automatic => maps:get(automatic,Policy,false)}
    end,
    Next=S#{count := maps:get(count,S)+1},
    case Late of
        N when is_integer(N),N>=0 -> Next#{samples := maps:get(samples,S)+1,total_ns := maps:get(total_ns,S)+N};
        _ -> Next
    end;
add(_,_,S) -> S.

summary(#{count := Count,samples := Samples,total_ns := Total,policy := {Revision,Offset}}=S) when Count>=2 ->
    Base=#{discarded => Count,revision => Revision,response_ms => Offset,automatic => maps:get(automatic,S,false)},
    case Samples of
        N when N<2 -> Base;
        _ -> MeanMs=(Total+Samples*1000000-1) div (Samples*1000000),
             Base#{mean_late_ms => MeanMs,required_ms => Offset+MeanMs}
    end;
summary(_) -> none.

%% Diminishing gain with a soft approach to 3 s. Small deltas below 300 ms
%% are nearly unweighted; gains fall around 600 and 1000 ms. The delta term
%% also bounds a single huge measurement instead of jumping near the ceiling.
increase(Current,Required) when Required>Current,Current<2999 ->
    Delta=Required-Current,Headroom=min(2700,3000-Current),
    Step=Delta*300*Headroom*Headroom div ((max(300,Current)+Delta)*2700*2700),
    min(2999,Current+Step);
increase(Current,_) -> Current.

text(#{discarded := N}=Report) ->
    Measurement=case Report of
        #{mean_late_ms := Mean,required_ms := Required,response_ms := Current} ->
            io_lib:format(" Average lateness: ~B ms; estimated required Response time: ~B ms (current ~B ms).",[Mean,Required,Current]);
        _ -> " Increase Response time; this output did not report the amount of lateness."
    end,
    iolist_to_binary([io_lib:format("Audio warning: discarded ~B audio blocks because they missed their output time.",[N]),Measurement]).
