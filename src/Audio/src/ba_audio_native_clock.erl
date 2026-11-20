%% Session policy -> native clock calibration. No media or per-packet decisions.
-module(ba_audio_native_clock).
-export([plan/5,ready/0]).
module() -> ba_settings:app(audio_clock_adapter,ba_session_clock).
ready() -> M=module(),case M:presentation([]) of {ok,_} -> true;_ -> false end.
plan(#{<<"internal_ns">> := I,<<"session_ns">> := Native},Sent,Received,Descriptor,Previous)
        when is_integer(Sent),is_integer(Received),Received>=Sent ->
    try
        Internal=binary_to_integer(I),true=Internal>=0,
        M=module(),Mid=(Sent+Received) div 2,
        {ok,#{clock := Timeline,offset_ms := Delay,offset_revision := Policy,times := [Global]}}=M:presentation([Mid]),
        Timeline=maps:get(clock,Descriptor),true=is_integer(Delay) andalso Delay>=0 andalso Delay=<10000,
        case Previous of
            #{timeline := Timeline,offset_ms := Delay,policy_revision := Policy} -> ok;
            P when map_size(P)=:=0 -> ok;
            _ ->
                logger:warning("Native presentation changed: response ~p -> ~p ms, policy ~p -> ~p, same timeline ~p",
                    [maps:get(offset_ms,Previous,undefined),Delay,maps:get(policy_revision,Previous,undefined),Policy,
                     maps:get(timeline,Previous,undefined)=:=Timeline]),
                throw(presentation_changed)
        end,
        Limit=500,
        PPM=case Native of null -> 0;_ ->
            Error=Global-binary_to_integer(Native),max(-Limit,min(Limit,Error/5000))
        end,
        Revision=maps:get(revision,Previous,0)+1,
        Meta=#{timeline => Timeline,offset_ms => Delay,policy_revision => Policy,revision => Revision,
               local_round_trip_ns => Received-Sent},
        {ok,#{op => <<"clock_map">>,timeline => Timeline,internal_ns => I,session_ns => integer_to_binary(Global),
            revision => Revision,correction_ppm => PPM,max_absolute_ppm => Limit},Meta}
    catch throw:presentation_changed -> {error,presentation_changed};_ : _ -> {error,clock_mapping_unavailable} end;
plan(_,_,_,_,_) -> {error,invalid_native_clock_observation}.
