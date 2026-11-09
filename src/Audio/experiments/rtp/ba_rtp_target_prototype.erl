%% Isolated evaluation only; no production handler imports this module.
-module(ba_rtp_target_prototype).
-export([packet/5,target/2]).
packet(Audio,SamplePosition,Sequence,Target,ExtensionId)
        when is_integer(Target),Target>=0,Target<9223372036854775808,
             is_integer(ExtensionId),ExtensionId>0,ExtensionId<15 ->
    P='Elixir.ExRTP.Packet':new(Audio,[{timestamp,SamplePosition band 16#ffffffff},
        {sequence_number,Sequence band 16#ffff}]),
    E='Elixir.ExRTP.Packet.Extension':new(ExtensionId,<<1,Target:64>>),
    'Elixir.ExRTP.Packet':add_extension(P,E).
target(Packet,NegotiatedId) ->
    case 'Elixir.ExRTP.Packet':fetch_extension(Packet,NegotiatedId) of
        {ok,#{data := <<1,Target:64>>}} -> {ok,Target};
        _ -> {error,independent_packet_target_missing}
    end.
