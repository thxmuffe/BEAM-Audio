-module(ba_native_stop_tests).
-include_lib("eunit/include/eunit.hrl").

socket_ack_skips_earlier_data_test() -> peer(fun(S) ->
    {ok,<<4>>}=gen_tcp:recv(S,0,1000),
    ok=gen_tcp:send(S,<<3,123>>),ok=gen_tcp:send(S,<<4>>)
end,fun(S) -> ?assertEqual(ok,ba_native_stop:socket(S,<<4>>,<<4>>)) end).
socket_eof_is_not_ack_test() -> peer(fun(S) ->
    {ok,<<4>>}=gen_tcp:recv(S,0,1000)
end,fun(S) -> ?assertEqual({error,native_stop_unconfirmed},ba_native_stop:socket(S,<<4>>,<<4>>)) end).
port_eof_is_not_ack_test() ->
    P=open_port({spawn_executable,"/usr/bin/true"},[binary,{packet,4},exit_status]),
    ?assertMatch({error,_},ba_native_stop:port(P,<<4>>,<<4>>)).
peer(Server,Client) ->
    {ok,L}=gen_tcp:listen(0,[binary,{packet,4},{active,false},{ip,{127,0,0,1}}]),
    {ok,{_,Port}}=inet:sockname(L),Parent=self(),
    {P,Ref}=spawn_monitor(fun() -> {ok,S}=gen_tcp:accept(L),try Server(S) after gen_tcp:close(S) end,Parent ! served end),
    {ok,C}=gen_tcp:connect({127,0,0,1},Port,[binary,{packet,4},{active,false}],1000),
    try Client(C),receive served -> ok after 2000 -> error(server_timeout) end,
        receive {'DOWN',Ref,process,P,normal} -> ok after 2000 -> error(server_failed) end
    after gen_tcp:close(C),gen_tcp:close(L) end.
