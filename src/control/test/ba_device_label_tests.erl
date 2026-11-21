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

ios_device_name_test() ->
    Old=[{K,os:getenv(K)} || K <- ["BA_PLATFORM","BA_DEVICE_NAME"]],
    try
        os:putenv("BA_PLATFORM","ios"),os:putenv("BA_DEVICE_NAME","Paavo's iPhone"),
        ?assertEqual("Paavo's iPhone",ba_device_label:os_name()),
        ?assertEqual(<<"iPhone | Paavo's iPhone | ABCDEF01">>,ba_device_label:local(<<"ABCDEF012345">>)),
        os:unsetenv("BA_DEVICE_NAME"),?assertEqual("iPhone",ba_device_label:os_name())
    after lists:foreach(fun({K,false}) -> os:unsetenv(K);({K,V}) -> os:putenv(K,V) end,Old) end.

native_app_hosting_device_web_is_not_web_test() ->
    Old=[{K,os:getenv(K)} || K <- ["BA_PLATFORM","BA_DEVICE_NAME","BA_NATIVE_APP"]],
    Origin=persistent_term:get({ba_device_web,origin},undefined),
    try
        os:putenv("BA_PLATFORM","windows"),os:putenv("BA_DEVICE_NAME","PC"),
        persistent_term:put({ba_device_web,origin},<<"http://127.0.0.1:57528">>),
        Type=ba_device_label:display(<<"PC">>),
        ?assertEqual(<<Type/binary," | Web | 57528 | ABCDEF01">>,ba_device_label:local(<<"ABCDEF012345">>)),
        os:putenv("BA_NATIVE_APP","1"),
        ?assertEqual(<<Type/binary," | ABCDEF01">>,ba_device_label:local(<<"ABCDEF012345">>))
    after
        lists:foreach(fun({K,false}) -> os:unsetenv(K);({K,V}) -> os:putenv(K,V) end,Old),
        case Origin of undefined -> persistent_term:erase({ba_device_web,origin});V -> persistent_term:put({ba_device_web,origin},V) end
    end.

observer_label_is_visible_before_the_host_name_test() ->
    Old=[{K,os:getenv(K)} || K <- ["BA_PLATFORM","BA_DEVICE_NAME"]],
    Observer=application:get_env(ba_core,session_observer),
    try
        os:putenv("BA_PLATFORM","mac"),os:putenv("BA_DEVICE_NAME","Test Mac"),
        application:set_env(ba_core,session_observer,true),
        ?assertEqual(<<"Inspector Mac | Test Mac | ABCDEF01">>,ba_device_label:local(<<"ABCDEF012345">>)),
        application:set_env(ba_core,session_observer,false),
        ?assertEqual(<<"Mac | Test Mac | ABCDEF01">>,ba_device_label:local(<<"ABCDEF012345">>))
    after
        lists:foreach(fun({K,false}) -> os:unsetenv(K);({K,V}) -> os:putenv(K,V) end,Old),
        case Observer of undefined -> application:unset_env(ba_core,session_observer);{ok,V} -> application:set_env(ba_core,session_observer,V) end
    end.

windows_family_type_test() ->
    Reg=fun(V) -> "\r\nHKEY_LOCAL_MACHINE\\HARDWARE\\DESCRIPTION\\System\\BIOS\r\n    SystemFamily    REG_SZ    "++V++"\r\n\r\n" end,
    ?assertEqual(<<"ThinkPad">>,ba_device_label:family_type(Reg("ThinkPad E14 Gen 3"))),
    ?assertEqual(<<"Latitude">>,ba_device_label:family_type(Reg("Latitude"))),
    ?assertEqual(<<"Windows">>,ba_device_label:family_type(Reg("To be filled by O.E.M."))),
    ?assertEqual(<<"Windows">>,ba_device_label:family_type(Reg("Default string"))),
    ?assertEqual(<<"Windows">>,ba_device_label:family_type("ERROR: The system was unable to find the specified registry key or value.")).
