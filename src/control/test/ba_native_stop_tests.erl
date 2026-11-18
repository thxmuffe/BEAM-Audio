-module(ba_native_stop_tests).
-include_lib("eunit/include/eunit.hrl").

socket_ack_skips_earlier_data_test() -> peer(fun(S) ->
    {ok,<<4>>}=gen_tcp:recv(S,0,1000),
    ok=gen_tcp:send(S,<<3,123>>),ok=gen_tcp:send(S,<<4>>)
end,fun(S) -> ?assertEqual(ok,ba_native_stop:socket(S,<<4>>,<<4>>)) end).
socket_eof_is_not_ack_test() -> peer(fun(S) ->
    {ok,<<4>>}=gen_tcp:recv(S,0,1000)
end,fun(S) -> ?assertEqual({error,native_stop_unconfirmed},ba_native_stop:socket(S,<<4>>,<<4>>)) end).
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
peer(Server,Client) ->
    {ok,L}=gen_tcp:listen(0,[binary,{packet,4},{active,false},{ip,{127,0,0,1}}]),
    {ok,{_,Port}}=inet:sockname(L),Parent=self(),
    {P,Ref}=spawn_monitor(fun() -> {ok,S}=gen_tcp:accept(L),try Server(S) after gen_tcp:close(S) end,Parent ! served end),
    {ok,C}=gen_tcp:connect({127,0,0,1},Port,[binary,{packet,4},{active,false}],1000),
    try Client(C),receive served -> ok after 2000 -> error(server_timeout) end,
        receive {'DOWN',Ref,process,P,normal} -> ok after 2000 -> error(server_failed) end
    after gen_tcp:close(C),gen_tcp:close(L) end.
