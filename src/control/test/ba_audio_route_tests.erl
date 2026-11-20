-module(ba_audio_route_tests).
-include_lib("eunit/include/eunit.hrl").

%% ICE must receive the configured hostname, including when this process has
%% no DNS answer. The library resolves it on the network used by its socket.
ice_server_names_reach_library_test() ->
    Keys=[direct_stun_urls,audio_turn_servers],
    Old=[{K,application:get_env(ba_core,K)} || K <- Keys],
    try
        application:set_env(ba_core,direct_stun_urls,[<<"stun:stun.example.invalid:19302">>]),
        application:set_env(ba_core,audio_turn_servers,
            [#{host => <<"turn.example.invalid">>,port => 3478,username => <<"user">>,password => <<"secret">>}]),
        ?assertEqual(#{stun => [<<"stun.example.invalid">>,19302],
            turn => [[<<"turn.example.invalid">>,3478,<<"user">>,<<"secret">>]]},ba_audio_route:ice_config()),
        application:set_env(ba_core,direct_stun_urls,[<<"stun:stun.example.invalid">>]),
        ?assertEqual([<<"stun.example.invalid">>,3478],maps:get(stun,ba_audio_route:ice_config())),
        application:set_env(ba_core,direct_stun_urls,[]),
        application:set_env(ba_core,audio_turn_servers,[]),
        ?assertEqual(#{stun => undefined,turn => []},ba_audio_route:ice_config())
    after
        [case V of {ok,Value} -> application:set_env(ba_core,K,Value);
            undefined -> application:unset_env(ba_core,K) end || {K,V} <- Old]
    end.
