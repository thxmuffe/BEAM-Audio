-module(ba_rtp_target_prototype_tests).
-include_lib("eunit/include/eunit.hrl").
independent_target_and_standard_rtp_wrap_test() ->
    T=1794216659443562501,
    A=ba_rtp_target_prototype:packet(<<1>>,16#ffffffff-479,65535,T,7),
    B=ba_rtp_target_prototype:packet(<<2>>,16#ffffffff+481,65536,T+20000001,7),
    ?assertEqual(480,maps:get(timestamp,B)),?assertEqual(0,maps:get(sequence_number,B)),
    [begin
        Wire='Elixir.ExRTP.Packet':encode(Packet),
        {ok,Decoded}='Elixir.ExRTP.Packet':decode(Wire),
        ?assertEqual({ok,Time},ba_rtp_target_prototype:target(Decoded,7)),
        ?assertEqual({error,independent_packet_target_missing},ba_rtp_target_prototype:target(Decoded,8))
     end || {Packet,Time} <- [{B,T+20000001},{A,T}]],
    Missing='Elixir.ExRTP.Packet':remove_extension(B,7),
    ?assertEqual({error,independent_packet_target_missing},ba_rtp_target_prototype:target(Missing,7)).
