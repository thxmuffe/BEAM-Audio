-module(ba_native_stop_tests).
-include_lib("eunit/include/eunit.hrl").

%% The helper's own exit (seen through waitpid) proves it stopped.
port_exit_confirms_stop_test() ->
    P=sleeper("0.2"),
    ?assertEqual(ok,ba_native_stop:port(P,<<4>>,<<4>>)).
%% A helper that never answers is killed, and confirmed only by its exit.
port_silent_helper_is_killed_test_() -> {timeout,10,fun() ->
    P=sleeper("30"),
    {os_pid,OsPid}=erlang:port_info(P,os_pid),
    ?assertEqual(ok,ba_native_stop:port(P,<<4>>,<<4>>)),
    ?assertNot(alive(OsPid))
end}.
%% A port already gone (its exit consumed elsewhere) cannot confirm anything.
port_closed_is_not_ack_test() ->
    P=sleeper("30"),
    port_close(P),
    ?assertEqual({error,native_stop_unconfirmed},ba_native_stop:port(P,<<4>>,<<4>>)).
%% A helper that reads its stop command, never answers, and exits after
%% Seconds. Like a real helper it consumes stdin: on Windows a child that exits
%% with unread input yields only {'EXIT',Port,epipe}, never an exit_status.
%% Python exists on every development host (python3 on macOS, python on Windows).
sleeper(Seconds) ->
    Python=case os:find_executable("python3") of false -> os:find_executable("python");P -> P end,
    open_port({spawn_executable,Python},[binary,{packet,4},exit_status,
        {args,["-c","import sys,time; sys.stdin.buffer.read(5); time.sleep("++Seconds++")"]}]).
alive(OsPid) ->
    Pid=integer_to_list(OsPid),
    case os:type() of
        {win32,_} -> string:find(os:cmd("tasklist /FI \"PID eq "++Pid++"\" /NH"),Pid)=/=nomatch;
        _ -> string:trim(os:cmd("ps -o pid= -p "++Pid))=/=""
    end.
