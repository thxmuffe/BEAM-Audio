-module(ba_desk_directory_tests).
-include_lib("eunit/include/eunit.hrl").

directory_test() ->
    {ok, Pid} = ba_desk_directory:start_link(),
    try
        ?assertEqual([], ba_desk_directory:nodes()),
        ?assertEqual({ok, [<<"mac@127.0.0.1">>]}, ba_desk_directory:register(<<"mac@127.0.0.1">>)),
        ?assertEqual({ok, [<<"mac@127.0.0.1">>]}, ba_desk_directory:register(<<"mac@127.0.0.1">>)),
        {ok, Both} = ba_desk_directory:register(<<"phone@192.168.1.5">>),
        ?assertEqual(2, length(Both)),
        ?assertEqual({error, invalid_node_id}, ba_desk_directory:register(<<"<script>@host">>)),
        ?assertEqual({error, invalid_node_id}, ba_desk_directory:register(123)),
        ?assertEqual({error, invalid_node_id}, ba_desk_directory:register(binary:copy(<<"x">>, 256))),
        ?assertEqual(2, length(ba_desk_directory:nodes())),
        [ba_desk_directory:register(iolist_to_binary(["n", integer_to_list(I), "@host"])) || I <- lists:seq(1, 254)],
        ?assertEqual(256, length(ba_desk_directory:nodes())),
        ?assertEqual({error, directory_full}, ba_desk_directory:register(<<"extra@host">>)),
        ?assertMatch({ok, _}, ba_desk_directory:register(<<"mac@127.0.0.1">>))
    after gen_server:stop(Pid) end,
    {ok, Fresh} = ba_desk_directory:start_link(),
    ?assertEqual([], ba_desk_directory:nodes()),
    gen_server:stop(Fresh).
