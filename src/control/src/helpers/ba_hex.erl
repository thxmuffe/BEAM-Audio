%% Identifiers on the wire are upper-case hex of an exact length
%% (binary:encode_hex/1 output): 32 for random IDs, 64 for Device keys.
-module(ba_hex).
-export([valid/2]).

valid(B,N) when is_binary(B),byte_size(B) =:= N ->
    re:run(B,<<"^[0-9A-F]+$">>,[{capture,none}]) =:= match;
valid(_,_) -> false.
