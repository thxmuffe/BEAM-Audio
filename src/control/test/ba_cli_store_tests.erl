-module(ba_cli_store_tests).
-include_lib("eunit/include/eunit.hrl").
reserve_test() ->
    Old=os:getenv("BA_CLI_HOME"),
    D=filename:join("/tmp","ba-cli-slots-"++integer_to_list(erlang:unique_integer([positive]))),
    os:putenv("BA_CLI_HOME",D),
    try
        R=#{instance => <<"TEST">>,socket => <<"unused">>},
        {ok,"OpenSound",_}=ba_cli_store:reserve("OpenSound",true,R),
        ?assertEqual({error,already_running},ba_cli_store:reserve("OpenSound",false,R)),
        Parent=self(),
        [spawn(fun() -> Parent ! {reserved,ba_cli_store:reserve("OpenSound",true,R)} end) || _ <- lists:seq(1,4)],
        Names=[receive {reserved,{ok,N,_}} -> N after 2000 -> error(timeout) end || _ <- lists:seq(1,4)],
        ?assertEqual(["OpenSound-2","OpenSound-3","OpenSound-4","OpenSound-5"],lists:sort(Names)),
        {ok,#{<<"name">> := <<"OpenSound">>}}=ba_cli_store:read("OpenSound")
    after
        case Old of false -> os:unsetenv("BA_CLI_HOME");_ -> os:putenv("BA_CLI_HOME",Old) end,
        file:del_dir_r(D)
    end.
