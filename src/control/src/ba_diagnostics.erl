%% Bounded, payload-free failure counters, kept by each existing OTP owner.
-module(ba_diagnostics).
-export([count/2,view/1,reason/1]).
view(S) -> maps:get(diagnostics,S,#{counts => #{},last_error => null}).
count(Reason,S) ->
    D = view(S),Counts = maps:get(counts,D),R0 = reason(Reason),
    R = case is_map_key(R0,Counts) orelse map_size(Counts)<31 of true -> R0;false -> other end,
    S#{diagnostics => D#{counts := Counts#{R => maps:get(R,Counts,0)+1},last_error := R}}.
reason(R) when is_atom(R) -> R;
reason({R,Stack}) when is_atom(R),is_list(Stack) -> R;
reason(<<"decoded_packet_target_missing">>) -> decoded_packet_target_missing;
reason(<<"unsupported_decoded_block">>) -> unsupported_decoded_block;
reason(<<"native_input_overloaded">>) -> native_input_overloaded;
reason(<<"native_decoder_failed">>) -> native_decoder_failed;
reason(_) -> invalid_or_unsupported.
