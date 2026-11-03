%% On-demand read of one admitted node over an existing route. No cluster-wide broadcasts.
-module(parvi_node_diagnostics).
-export([read/1, snapshot/0]).

read(Name) when is_binary(Name) ->
    case parvi_node_api:request(#{<<"op">> => <<"inspect">>, <<"node">> => Name}) of
        {ok,Snapshot} -> {ok,#{node_diagnostics => Snapshot}};
        Error -> Error
    end.

snapshot() ->
    Receive = maps:with([handler,receiver,playback,native_statistics],parvi_audio_receiver:snapshot()),
    #{node => atom_to_binary(node()), sampled_at_ms => erlang:system_time(millisecond), audio_receive => Receive}.
