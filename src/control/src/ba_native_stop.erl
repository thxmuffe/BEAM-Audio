%% Explicit native acknowledgements; EOF is never substituted for an ACK.
-module(ba_native_stop).
-export([port/3,socket/3]).
port(Port,Command,Ack) ->
    try true=port_command(Port,Command),port_reply(Port,Ack,deadline())
    catch _:_ -> {error,native_stop_unconfirmed} end.
port_reply(Port,Ack,Deadline) ->
    Remaining=Deadline-erlang:monotonic_time(millisecond),
    case Remaining>0 of false -> {error,native_stop_timeout};true -> receive
        {Port,{data,Ack}} -> ok;
        {Port,{data,_}} -> port_reply(Port,Ack,Deadline);
        {Port,{exit_status,_}} -> {error,native_stop_unconfirmed};
        {'EXIT',Port,_} -> {error,native_stop_unconfirmed}
    after Remaining -> {error,native_stop_timeout} end end.
socket(Socket,Command,Ack) ->
    try ok=inet:setopts(Socket,[{active,false}]),ok=gen_tcp:send(Socket,Command),socket_reply(Socket,Ack,deadline())
    catch _:_ -> {error,native_stop_unconfirmed} end.
socket_reply(Socket,Ack,Deadline) ->
    Remaining=Deadline-erlang:monotonic_time(millisecond),
    case Remaining>0 of false -> {error,native_stop_timeout};true -> case gen_tcp:recv(Socket,0,Remaining) of
        {ok,Ack} -> ok;
        {ok,_} -> socket_reply(Socket,Ack,Deadline);
        _ -> {error,native_stop_unconfirmed}
    end end.
deadline() -> erlang:monotonic_time(millisecond)+1500.
