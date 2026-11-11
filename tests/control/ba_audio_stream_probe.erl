%% Test-only clock and output binding. Never bundled with product apps.
-module(ba_audio_stream_probe).
-export([command/1,id/0,now/0,status/0,to_monotonic/1,from_monotonic/1,open/1,write/4,close/1]).
id() -> <<"headless-shared-test-clock">>.
now() -> {ok,erlang:system_time(nanosecond)}.
status() -> #{state => synchronized,role => master,last_sync => erlang:monotonic_time(nanosecond),filtered_utc_time => erlang:system_time(nanosecond)}.
to_monotonic(Time) -> {ok,Time-erlang:time_offset(nanosecond)}.
from_monotonic(Time) -> {ok,Time+erlang:time_offset(nanosecond)}.
open(_) -> {ok,#{latency_ns => 0,observer => whereis(ba_audio_test_sink)}}.
write(#{observer := Observer},Time,Frames,PCM) ->
    Clock = application:get_env(ba_core,audio_clock_adapter,ba_buffee_clock),
    {ok,Target} = Clock:from_monotonic(Time),{ok,Written} = Clock:now(),
    case process_info(Observer,message_queue_len) of
        {message_queue_len,N} when N<128 ->
            Observer ! {output,#{target_ns => Target,frames => Frames,write_ns => Written},PCM},ok;
        _ -> {error,output_probe_overloaded}
    end.
start_observer() ->
    register(ba_audio_test_sink,spawn_link(fun observe/0)).
observe() ->
    receive
        {output,Header,PCM} ->
            Values = [V || <<V:32/little-float>> <= PCM],
            Record = Header#{peak => lists:max([abs(V) || V <- Values]),first => hd(Values),
                minimum => lists:min(Values),maximum => lists:max(Values)},
            update_stats(Record),
            ets:insert(ba_audio_test_output,{erlang:unique_integer([positive,monotonic]),Record}),
            case ets:info(ba_audio_test_output,size)>128 of
                true -> ets:delete(ba_audio_test_output,ets:first(ba_audio_test_output));false -> ok
            end,
            observe();
        {barrier,Ref,Caller} -> Caller ! {Ref,ok},observe()
    end.
output_barrier() ->
    Ref = make_ref(),Caller = self(),Observer = whereis(ba_audio_test_sink),
    %% Order the barrier behind every accepted write from the Mixer process.
    sys:replace_state(ba_audio_mixer,fun(S) -> Observer ! {barrier,Ref,Caller},S end),
    receive {Ref,ok} -> ok after 5000 -> error(output_probe_timeout) end.
close(_) -> ok.
command(#{<<"op">> := <<"buffee_audio_prepare">>}) ->
    _ = ets:new(ba_audio_test_output,[named_table,public,ordered_set]),
    _ = ets:new(ba_audio_test_stats,[named_table,public]),
    start_observer(),
    application:unset_env(ba_core,audio_clock_adapter),
    application:set_env(ba_core,audio_output_adapter,?MODULE),
    result(ba_audio_sup:ensure_started());
command(#{<<"op">> := <<"audio_prepare">>}) ->
    _ = ets:new(ba_audio_test_output,[named_table,public,ordered_set]),
    _ = ets:new(ba_audio_test_stats,[named_table,public]),
    start_observer(),
    application:set_env(ba_core,audio_clock_adapter,?MODULE),
    application:set_env(ba_core,audio_output_adapter,?MODULE),
    result(ba_audio_sup:ensure_started());
command(#{<<"op">> := <<"audio_restart_receiver">>}) ->
    Old = whereis(ba_audio_receiver),Ref = monitor(process,Old),exit(Old,kill),
    receive {'DOWN',Ref,process,Old,_} -> ok after 1000 -> error(receiver_not_down) end,
    await_receiver(Old,100),#{ok => true};
command(#{<<"op">> := <<"audio_ids">>}) ->
    S = sys:get_state(ba_audio_receiver),
    #{subscriptions => maps:map(fun(_,R) -> pid_string(maps:get(session,R)) end,maps:get(subscriptions,S)),
      providers => lists:sort([pid_string(maps:get(session,R)) || R <- maps:values(maps:get(providers,S))]),
      sources => maps:map(fun(_,E) -> #{pid => pid_string(maps:get(pid,E)),incarnation => maps:get(incarnation,maps:get(offer,E))} end,maps:get(sources,S))};
command(#{<<"op">> := <<"audio_stats">>}) ->
    output_barrier(),
    case ets:lookup(ba_audio_test_stats,summary) of [{_,V}] -> V;[] -> #{frames => 0} end;
command(#{<<"op">> := <<"audio_reset_stats">>}) -> output_barrier(),ets:delete_all_objects(ba_audio_test_stats),#{ok => true};
command(#{<<"op">> := <<"audio_snapshot">>}) -> ba_audio_receiver:snapshot();
command(#{<<"op">> := <<"audio_output">>}) -> output_barrier(),#{blocks => [R || {_,R} <- ets:tab2list(ba_audio_test_output)]};
command(#{<<"op">> := <<"audio_clear_output">>}) -> output_barrier(),ets:delete_all_objects(ba_audio_test_output),#{ok => true};
command(#{<<"op">> := <<"publish_opus">>,<<"source">> := Key,<<"fixture">> := File}) ->
    D = #{encoding => opus,sample_format => opus,sample_rate => 48000,channel_count => 2,clock => clock_id(),
        stream_handler => webrtc_audio_opus,rtp_timestamp_semantics => global_playback_48k_v1},
    {ok,Data} = file:read_file(File),put(opus_fixture,fixture(Data,[])),
    case ba_audio:publish(#{source_key => Key,name => Key,profiles => #{channel => D}},self()) of
        {ok,Pid} -> put({source,Key},Pid),put({descriptor,Key},D),#{ok => true};Error -> result(Error)
    end;
command(#{<<"op">> := <<"push_opus">>,<<"source">> := Key,<<"target_ns">> := Target,<<"index">> := Index}) ->
    Timing = #{continuous => true,presentation => #{target_output_time_ns => Target}},
    case gen_server:call(get({source,Key}),{push_encoded,Timing,lists:nth(Index+1,get(opus_fixture))}) of
        {ok,Replies} -> #{ok => true,deliveries => length([ok || {_,ok} <- Replies])};Error -> result(Error)
    end;
command(#{<<"op">> := <<"publish">>,<<"source">> := Key,<<"format">> := F,<<"channels">> := Channels}) ->
    Format = format(F),
    D = #{encoding => pcm,sample_format => Format,sample_rate => 48000,channel_count => Channels,clock => clock_id()},
    case ba_audio:publish(#{source_key => Key,name => Key,profiles => #{channel => D}},self()) of
        {ok,Pid} -> put({source,Key},Pid),put({descriptor,Key},D),#{ok => true};
        Error -> result(Error)
    end;
command(#{<<"op">> := <<"unpublish">>,<<"source">> := Key}) -> result(ba_audio:unpublish(get({source,Key})));
command(#{<<"op">> := <<"pause_source">>,<<"source">> := Key,<<"paused">> := B}) -> result(ba_audio:pause(get({source,Key}),B));
command(#{<<"op">> := <<"capture_source">>,<<"source">> := Key,<<"capture_ns">> := Capture,<<"value">> := Value,<<"frames">> := Frames}) ->
    D = get({descriptor,Key}),PCM = pcm(Key,Value,Frames),
    {ok,Mono} = ba_buffee_clock:to_monotonic(Capture),
    Input = (ba_audio_input:new())#{descriptor => D,source => get({source,Key}),handler => ba_stream_handler_pcm},
    Next = ba_audio_input:captured(PCM,Mono,Input),
    put({descriptor,Key},maps:get(descriptor,Next)),
    #{ok => true,blocks => maps:get(blocks,Next),send_errors => maps:get(send_errors,Next)};
command(#{<<"op">> := <<"push_source">>,<<"source">> := Key,<<"target_ns">> := Target,<<"value">> := Value,<<"frames">> := Frames}) ->
    PCM = pcm(Key,Value,Frames),
    case ba_audio:push(get({source,Key}),channel,#{playback_time => Target,channel_id => 0},PCM) of
        {ok,Replies} -> #{ok => true,deliveries => length([ok || {_,ok} <- Replies])};
        Error -> result(Error)
    end;
command(#{<<"op">> := <<"audio_contract">>,<<"direction">> := Direction,<<"peer">> := Peer,
          <<"source">> := Source,<<"contract">> := Id}) ->
    D = case Direction of <<"publish">> -> publish;<<"receive">> -> receive_audio end,
    result(ba_audio_receiver:set_contract(D,Peer,Source,Id,1));
command(#{<<"op">> := <<"audio_clear_contract">>,<<"direction">> := Direction,<<"peer">> := Peer,<<"source">> := Source}) ->
    D = case Direction of <<"publish">> -> publish;<<"receive">> -> receive_audio end,
    result(ba_audio_receiver:clear_contract(D,Peer,Source));
command(#{<<"op">> := <<"audio_subscribe">>,<<"peer">> := Peer,<<"source">> := Key}) -> result(ba_audio_receiver:subscribe(Peer,Key,channel));
command(#{<<"op">> := <<"audio_play">>,<<"id">> := Id,<<"playing">> := B}) ->
    result(ba_audio_receiver:playback(Id,case B of true -> start;false -> stop end));
command(#{<<"op">> := <<"audio_unsubscribe">>,<<"id">> := Id}) -> result(ba_audio_receiver:stop(Id));
command(#{<<"op">> := <<"audio_gain">>,<<"id">> := Id,<<"gain">> := G}) -> result(ba_audio_receiver:gain(Id,G)).
format(<<"float32_le">>) -> float32_le;
format(<<"pcm16_le">>) -> pcm16_le.
result(ok) -> #{ok => true};
result({ok,V}) -> #{ok => true,value => V};
result({error,R}) -> #{error => R}.

await_receiver(_,0) -> error(receiver_not_restarted);
await_receiver(Old,N) ->
    case whereis(ba_audio_receiver) of
        New when is_pid(New),New=/=Old -> gen_server:call(New,snapshot),ok;
        _ -> receive after 10 -> await_receiver(Old,N-1) end
    end.

clock_id() -> Module = application:get_env(ba_core,audio_clock_adapter,ba_buffee_clock),Module:id().

pcm(Key,Value,Frames) ->
    D = get({descriptor,Key}),Sample = case maps:get(sample_format,D) of
        float32_le -> <<Value:32/little-float>>;
        pcm16_le -> <<(round(Value*32768)):16/little-signed>>
    end,binary:copy(Sample,Frames*maps:get(channel_count,D)).

fixture(<<>>,Acc) -> lists:reverse(Acc);
fixture(<<Size:32,Packet:Size/binary,Rest/binary>>,Acc) -> fixture(Rest,[Packet|Acc]).

pid_string(P) when is_pid(P) -> list_to_binary(pid_to_list(P));
pid_string(_) -> null.
update_stats(#{target_ns := Target,frames := Frames,peak := Peak,minimum := Min,maximum := Max,write_ns := Written}) ->
    Old = case ets:lookup(ba_audio_test_stats,summary) of
        [{_,V}] -> V;
        [] -> #{frames => 0,blocks => 0,gaps => 0,late => 0,bad_mix => 0,min_peak => Peak,max_peak => Peak,next => Target,first_target => Target}
    end,
    Next = Old#{frames := maps:get(frames,Old)+Frames,blocks := maps:get(blocks,Old)+1,
        gaps := maps:get(gaps,Old)+case abs(Target-maps:get(next,Old))>22000 of true -> 1;false -> 0 end,
        late := maps:get(late,Old)+case Written>=Target of true -> 1;false -> 0 end,
        bad_mix := maps:get(bad_mix,Old)+case abs(Min-0.75)>0.0001 orelse abs(Max-0.75)>0.0001 of true -> 1;false -> 0 end,
        min_peak := min(Peak,maps:get(min_peak,Old)),max_peak := max(Peak,maps:get(max_peak,Old)),
        next := Target+Frames*1000000000 div 48000},
    ets:insert(ba_audio_test_stats,{summary,Next}).
