-module(parvi_cluster_desk_tests).
-include_lib("eunit/include/eunit.hrl").

network_change_coalesces_and_keeps_membership_test() ->
    S = #{sessions => #{},online => [<<"peer">>],retry => undefined,backoff => 10000,
        peers => #{<<"peer">> => #{node => <<"peer@device">>}},mailbox => <<"cap">>,
        cluster => <<"cluster">>,event => starting},
    {noreply,Pending} = parvi_cluster_desk:handle_cast(network_changed,S),
    ?assertEqual({noreply,Pending},parvi_cluster_desk:handle_cast(network_changed,Pending)),
    receive {network_changed,Tag} = Event ->
        ?assertEqual(Tag,maps:get(network_change,Pending)),
        {noreply,Next} = parvi_cluster_desk:handle_info(Event,Pending),
        ?assertEqual(maps:with([peers,mailbox,cluster],S),maps:with([peers,mailbox,cluster],Next)),
        ?assertMatch(#{online := [],sessions := #{},backoff := 500,network_change := undefined},Next),
        ?assertEqual({noreply,Next},parvi_cluster_desk:handle_info(Event,Next))
    after 1500 -> error(no_network_event) end.

unavailable_closes_only_matching_attempt_test() ->
    {Target,TargetRef}=spawn_monitor(fun wait/0),
    {Other,OtherRef}=spawn_monitor(fun wait/0),
    State=#{sessions=>#{<<"attempt">>=>#{ctrl=>Target},<<"other">>=>#{ctrl=>Other}},event=>starting},
    try
        ?assertEqual({noreply,State},parvi_cluster_desk:handle_info(
            {relay,{error,<<"attempt">>,<<"unavailable">>}},State)),
        receive {'DOWN',TargetRef,process,Target,Reason}->
            ?assertEqual({shutdown,peer_unavailable},Reason)
        after 1000 -> error(attempt_not_closed) end,
        ?assert(is_process_alive(Other))
    after
        exit(Target,kill),exit(Other,kill),demonitor(TargetRef,[flush]),demonitor(OtherRef,[flush])
    end.

stale_unavailable_does_not_close_replacement_test() ->
    {Ctrl,Ref}=spawn_monitor(fun wait/0),
    State=#{sessions=>#{<<"new">>=>#{ctrl=>Ctrl}},event=>starting},
    try
        {noreply,_}=parvi_cluster_desk:handle_info(
            {relay,{error,<<"old">>,<<"unavailable">>}},State),
        ?assert(is_process_alive(Ctrl))
    after exit(Ctrl,kill),demonitor(Ref,[flush]) end.

wait() -> receive stop -> ok end.
