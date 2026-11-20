-module(ba_device_handler_speaker_tests).
-include_lib("eunit/include/eunit.hrl").
%% Without the audio automation Worker nothing subscribes or plays; the speaker
%% must say so rather than look idle-but-ready (Windows before its PCM binding).

speaker_without_worker_test() ->
    Keys=[audio_automation],
    Old=[{K,application:get_env(ba_core,K)} || K <- Keys],
    try
        application:set_env(ba_core,audio_automation,false),
        ba_test_consent:with(#{speaker => true},fun() ->
            ?assertMatch(#{state := unsupported,error := <<_/binary>>},ba_device_handler:no_worker_speaker(#{})),
            ?assertEqual(#{state => running},ba_device_handler:no_worker_speaker(#{streams => 1}))
        end),
        ?assertEqual(#{state => unsupported},ba_device_handler:no_worker_speaker(#{})),
        application:set_env(ba_core,audio_automation,true),
        ?assertEqual(#{state => ready},ba_device_handler:no_worker_speaker(#{}))
    after
        lists:foreach(fun({K,undefined}) -> application:unset_env(ba_core,K);({K,{ok,V}}) -> application:set_env(ba_core,K,V) end,Old)
    end.
