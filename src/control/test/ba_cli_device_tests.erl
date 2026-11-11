-module(ba_cli_device_tests).
-include_lib("eunit/include/eunit.hrl").

large_fragmented_reply_test() ->
    Reply=#{<<"devices">> => binary:copy(<<"device metrics ">>,10000)},
    Wire=iolist_to_binary([json:encode(Reply),$\n]),
    <<First:4096/binary,Rest/binary>>=Wire,
    ?assertEqual({ok,Reply},local_reply([First,Rest])).

malformed_reply_is_an_error_test() ->
    ?assertEqual({error,invalid_response},local_reply([<<"{\"devices\":\n">>])).

local_reply(Chunks) ->
    Path=filename:join("/tmp","ba-cli-reply-"++integer_to_list(erlang:unique_integer([positive]))++".sock"),
    {ok,L}=gen_tcp:listen(0,[local,binary,{ifaddr,{local,Path}},{packet,line},{active,false}]),
    {Pid,Ref}=spawn_monitor(fun() ->
        {ok,S}=gen_tcp:accept(L),
        {ok,_}=gen_tcp:recv(S,0,1000),
        [begin ok=gen_tcp:send(S,B),receive after 5 -> ok end end || B <- Chunks],
        gen_tcp:close(S)
    end),
    try
        ba_cli_device:call(#{<<"socket">> => list_to_binary(Path),<<"instance">> => <<"fixture">>},
                           #{<<"method">> => <<"monitor">>})
    after
        gen_tcp:close(L),file:delete(Path),
        receive {'DOWN',Ref,process,Pid,normal} -> ok;
                {'DOWN',Ref,process,Pid,Reason} -> error({reply_fixture_failed,Reason})
        after 1000 -> exit(Pid,kill),error(reply_fixture_timeout) end
    end.
