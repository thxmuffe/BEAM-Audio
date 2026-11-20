%% Explicit native acknowledgements; EOF is never substituted for an ACK.
%% A port helper is a child process: its OS exit status (waitpid, reported by
%% exit_status) proves it has stopped. A helper that does not acknowledge in time
%% is killed, like a supervisor's brutal_kill, and stops only once its exit is seen.
-module(ba_native_stop).
-export([port/3]).
port(Port,Command,Ack) ->
    try
        OsPid=case erlang:port_info(Port,os_pid) of {os_pid,P} -> P;_ -> undefined end,
        true=port_command(Port,Command),
        case port_reply(Port,Ack,deadline()) of
            {error,native_stop_timeout} when is_integer(OsPid) -> kill(Port,OsPid);
            Result -> Result
        end
    catch _:_ -> {error,native_stop_unconfirmed} end.
port_reply(Port,Ack,Deadline) ->
    Remaining=Deadline-erlang:monotonic_time(millisecond),
    case Remaining>0 of false -> {error,native_stop_timeout};true -> receive
        {Port,{data,Ack}} -> ok;
        {Port,{data,_}} -> port_reply(Port,Ack,Deadline);
        {Port,{exit_status,_}} -> ok;
        {'EXIT',Port,_} -> {error,native_stop_unconfirmed}
    after Remaining -> {error,native_stop_timeout} end end.
kill(Port,OsPid) ->
    _=os:cmd(case os:type() of
        {win32,_} -> "taskkill /F /PID "++integer_to_list(OsPid);
        _ -> "kill -9 "++integer_to_list(OsPid)
    end),
    receive {Port,{exit_status,_}} -> ok after 1500 -> {error,native_stop_timeout} end.
deadline() -> erlang:monotonic_time(millisecond)+1500.
