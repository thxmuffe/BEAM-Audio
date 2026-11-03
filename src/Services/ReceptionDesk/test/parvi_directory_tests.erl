-module(parvi_directory_tests).
-include_lib("eunit/include/eunit.hrl").

directory_test() ->
    {ok, Pid} = parvi_directory:start_link(),
    try
        ?assertEqual([], parvi_directory:nodes()),
        ?assertEqual({ok, [<<"mac@127.0.0.1">>]}, parvi_directory:register(<<"mac@127.0.0.1">>)),
        ?assertEqual({ok, [<<"mac@127.0.0.1">>]}, parvi_directory:register(<<"mac@127.0.0.1">>)),
        {ok, Both} = parvi_directory:register(<<"phone@192.168.1.5">>),
        ?assertEqual(2, length(Both)),
        ?assertEqual({error, invalid_node_id}, parvi_directory:register(<<"<script>@host">>)),
        ?assertEqual({error, invalid_node_id}, parvi_directory:register(123)),
        ?assertEqual({error, invalid_node_id}, parvi_directory:register(binary:copy(<<"x">>, 256))),
        ?assertEqual(2, length(parvi_directory:nodes())),
        [parvi_directory:register(iolist_to_binary(["n", integer_to_list(I), "@host"])) || I <- lists:seq(1, 254)],
        ?assertEqual(256, length(parvi_directory:nodes())),
        ?assertEqual({error, directory_full}, parvi_directory:register(<<"extra@host">>)),
        ?assertMatch({ok, _}, parvi_directory:register(<<"mac@127.0.0.1">>))
    after gen_server:stop(Pid) end,
    {ok, Fresh} = parvi_directory:start_link(),
    ?assertEqual([], parvi_directory:nodes()),
    gen_server:stop(Fresh).
