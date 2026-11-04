%% Every audio RTP timestamp is its sender-assigned global playback target.
%% Epoch: POSIX 1970-01-01; ticks: 1/48000 s; wire: low 32 bits (RFC RTP).
%% The shared clock resolves the wrap. No stream-relative timing anchor is used.
-module(parvi_audio_rtp_time).
-export([encode/1,decode/2,packet/4,semantics/0,quantize/1]).
semantics() -> global_playback_48k_v1.
quantize(Time) ->
    Ticks = (Time*48000+500000000) div 1000000000,
    (Ticks*1000000000+24000) div 48000.
encode(Time) when is_integer(Time),Time >= 0 ->
    ((Time*48000+500000000) div 1000000000) band 16#ffffffff.
decode(RTP,Now) when is_integer(RTP),RTP >= 0,RTP =< 16#ffffffff,is_integer(Now),Now >= 0 ->
    NowTicks = (Now*48000+500000000) div 1000000000,
    Delta = ((RTP-(NowTicks band 16#ffffffff)+16#80000000) band 16#ffffffff)-16#80000000,
    %% Configured presentation lead is <=30 s. Reject a remote/old epoch rather
    %% than accepting a random legacy RTP origin as a distant playback target.
    case abs(Delta) =< 60*48000 of
        true -> {ok,((NowTicks+Delta)*1000000000+24000) div 48000};
        false -> {error,packet_target_out_of_window}
    end;
decode(_,_) -> {error,invalid_packet_target}.
packet(Payload,#{continuous := true,presentation := #{target_output_time_ns := Target}},Seq,Marker)
        when is_integer(Target),Target >= 0 ->
    {ok,'Elixir.ExRTP.Packet':new(Payload,[{sequence_number,Seq},
        {timestamp,encode(Target)},{marker,Marker}])};
packet(_,_,_,_) -> {error,packet_playback_target_unavailable}.
