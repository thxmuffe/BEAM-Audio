-module(ba_session_chat_tests).
-include_lib("eunit/include/eunit.hrl").
%% Users see joins, on-air starts, requests and granted privileges; presence
%% changes, removals, losses and off-air are debug-level and never stored.

texts(#{messages := M}) -> [{maps:get(sender,E),maps:get(text,E)} || E <- lists:reverse(M)].
step(Message,S) -> {noreply,Next}=ba_session_chat:handle_info(Message,S),Next.

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
