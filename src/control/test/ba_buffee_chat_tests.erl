-module(ba_buffee_chat_tests).
-include_lib("eunit/include/eunit.hrl").
%% Users see joins, on-air starts, requests and granted privileges; presence
%% changes, removals, losses and off-air are debug-level and never stored.

texts(#{messages := M}) -> [{maps:get(sender,E),maps:get(text,E)} || E <- lists:reverse(M)].
step(Message,S) -> {noreply,Next}=ba_buffee_chat:handle_info(Message,S),Next.

visible_notices_test() ->
    S0=#{messages => [],present => [],privileges => undefined},
    S1=step({session_privileges,#{<<"A">> => [<<"owner">>]}},S0),
    S2=step({participants,[<<"A">>,<<"I">>]},S1),
    S3=step({session_privileges,#{<<"A">> => [<<"owner">>],<<"I">> => []}},S2),
    S4=step({participants,[<<"A">>]},S3),
    S5=step({participants,[<<"A">>,<<"I">>]},S4),
    S6=step({session_privileges,#{<<"A">> => [<<"owner">>],<<"I">> => [<<"stream_publish">>]}},S5),
    S7=step({on_air,<<"I">>,true},S6),
    S8=step({on_air,<<"I">>,false},S7),
    S9=step({session_privileges,#{<<"A">> => [<<"owner">>],<<"I">> => []}},S8),
    S10=step({session_privileges,#{<<"A">> => [<<"owner">>]}},S9),
    ?assertEqual([{<<"I">>,<<"joined the Session">>},{<<"I">>,<<"can now go on air">>},{<<"I">>,<<"is going on air">>}],texts(S10)),
    ?assert(lists:all(fun(E) -> maps:get(level,E)=:=info end,maps:get(messages,S10))).

audio_deadline_warning_is_shared_and_rate_limited_test() ->
    Member=spawn(fun Loop() -> receive {'$gen_call',From,current} ->
        gen_server:reply(From,{ok,#{policy => #{peers => #{}}}}),Loop() end end),
    register(ba_buffee_membership,Member),
    try
        Report=#{discarded => 12,mean_late_ms => 80,required_ms => 380,response_ms => 300},
        S1=step({audio_lateness,Report},#{messages => []}),
        ?assertEqual(1,length(maps:get(messages,S1))),
        [Entry]=maps:get(messages,S1),
        ?assertNotEqual(nomatch,binary:match(maps:get(text,Entry),<<"380 ms">>)),
        S2=step({audio_lateness,Report},S1),?assertEqual(S1,S2),
        S3=step({audio_lateness,Report},S2#{last_audio_warning := maps:get(last_audio_warning,S2)-30000}),
        ?assertEqual(2,length(maps:get(messages,S3)))
    after unregister(ba_buffee_membership),exit(Member,kill) end.
