-module(ba_swarm_log_tests).
-include_lib("eunit/include/eunit.hrl").

event(Reason) ->
    #{msg => {report,#{label => {supervisor,child_terminated},report =>
        [{supervisor,{local,ba_device_sup}},{reason,Reason},
         {offender,[{id,private_id},{mfargs,{ba_device_handler,start_link,[<<"PRIVATE_ARGUMENT">>]}}]}]}}}.

summary_does_not_forward_exception_data_test() ->
    ok=ba_swarm_log_h:log(event({{badmatch,<<"PRIVATE_EXCEPTION">>},[]}),#{config => #{recipient => self()}}),
    receive {ba_crash_notice,Text} ->
        ?assertEqual(<<"System: ba_device_handler stopped (badmatch).">>,Text),
        ?assertEqual(nomatch,binary:match(Text,<<"PRIVATE">>))
    after 100 -> error(no_notice) end.

normal_shutdown_and_other_logs_are_ignored_test() ->
    Config=#{config => #{recipient => self()}},
    [ok=ba_swarm_log_h:log(event(R),Config) || R <- [normal,shutdown,{shutdown,anything}]],
    ok=ba_swarm_log_h:log(#{msg => {string,"ordinary log"}},Config),
    receive {ba_crash_notice,_} -> error(unexpected_notice) after 0 -> ok end.

stalled_chat_queue_is_bounded_test() ->
    Pid=spawn(fun() -> receive stop -> ok end end),
    try
        [ok=ba_swarm_log_h:log(event(killed),#{config => #{recipient => Pid}}) || _ <- lists:seq(1,100)],
        ?assertEqual({message_queue_len,16},process_info(Pid,message_queue_len))
    after exit(Pid,kill) end.
