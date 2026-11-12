-module(ba_device_label_tests).
-include_lib("eunit/include/eunit.hrl").
labels_test() ->
    A=ba_device_label:format(<<"MacBook Air">>,<<>>,<<"ABCDEF012345">>),
    ?assertEqual(<<"MacBook Air | ABCDEF01">>,A),
    ?assertNotEqual(A,ba_device_label:format(<<"MacBook Air">>,<<>>,<<"12345678FFFF">>)),
    ?assertEqual(<<"OpenSound | Web | 64416 | ABCDEF01">>,
        ba_device_label:format(<<"OpenSound">>,<<"http://127.0.0.1:64416">>,<<"ABCDEF012345">>)),
    ?assertEqual(<<"Paavo’s iPhone (2) | ABCDEF01"/utf8>>,
        ba_device_label:format(<<"Paavo’s iPhone (2)"/utf8>>,<<>>,<<"ABCDEF012345">>)),
    Long=ba_device_label:format(unicode:characters_to_binary(lists:duplicate(100,16#1F600)),
        <<"http://127.0.0.1:65535">>,<<"ABCDEF012345">>),
    ?assert(byte_size(Long)=<256),?assert(is_list(unicode:characters_to_list(Long))).

platform_labels_test() ->
    Old=os:getenv("BA_PLATFORM"),
    try
        os:putenv("BA_PLATFORM","mac"),
        ?assertEqual(<<"Mac | BC-CG69">>,ba_device_label:display(<<"BC-CG69">>)),
        os:putenv("BA_PLATFORM","ios"),
        ?assertEqual(<<"iPhone | Paavo’s iPhone"/utf8>>,ba_device_label:display(<<"Paavo’s iPhone"/utf8>>))
    after case Old of false -> os:unsetenv("BA_PLATFORM");_ -> os:putenv("BA_PLATFORM",Old) end end.
