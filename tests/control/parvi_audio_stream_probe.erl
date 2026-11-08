%% Test-only clock and output binding. Never bundled with product apps.
-module(parvi_audio_stream_probe).
-export([command/1,id/0,now/0,status/0,to_monotonic/1,open/1,write/4,close/1]).
id() -> <<"headless-shared-test-clock">>.
now() -> {ok,erlang:system_time(nanosecond)}.
status() -> #{role => master,filtered_utc_time => erlang:system_time(nanosecond)}.
to_monotonic(Time) -> {ok,Time-erlang:time_offset(nanosecond)}.
open(_) -> {ok,#{latency_ns => 0}}.
write(_,Time,Frames,PCM) ->
    Values = [V || <<V:32/little-float>> <= PCM],
    Record = #{target_ns => Time+erlang:time_offset(nanosecond),frames => Frames,
        peak => lists:max([abs(V) || V <- Values]),first => hd(Values),
        write_ns => erlang:system_time(nanosecond)},
    ets:insert(parvi_audio_test_output,{erlang:unique_integer([positive,monotonic]),Record}),
    case ets:info(parvi_audio_test_output,size)>128 of true -> ets:delete(parvi_audio_test_output,ets:first(parvi_audio_test_output));false -> ok end,ok.
close(_) -> ok.
command(#{<<"op">> := <<"audio_prepare">>}) ->
    _ = ets:new(parvi_audio_test_output,[named_table,public,ordered_set]),
    application:set_env(parvi,audio_clock_adapter,?MODULE),
    application:set_env(parvi,audio_output_adapter,?MODULE),
    result(parvi_audio_sup:ensure_started());
command(#{<<"op">> := <<"audio_restart_receiver">>}) ->
    Old = whereis(parvi_audio_receiver),Ref = monitor(process,Old),exit(Old,kill),
    receive {'DOWN',Ref,process,Old,_} -> ok after 1000 -> error(receiver_not_down) end,
    await_receiver(Old,100),#{ok => true};
command(#{<<"op">> := <<"audio_snapshot">>}) -> parvi_audio_receiver:snapshot();
command(#{<<"op">> := <<"audio_output">>}) -> #{blocks => [R || {_,R} <- ets:tab2list(parvi_audio_test_output)]};
command(#{<<"op">> := <<"audio_clear_output">>}) -> ets:delete_all_objects(parvi_audio_test_output),#{ok => true};
command(#{<<"op">> := <<"publish">>,<<"source">> := Key,<<"format">> := F,<<"channels">> := Channels}) ->
    Format = format(F),
    D = #{encoding => pcm,sample_format => Format,sample_rate => 48000,channel_count => Channels,clock => id()},
    case parvi_audio:publish(#{source_key => Key,name => Key,profiles => #{channel => D}},self()) of
        {ok,Pid} -> put({source,Key},Pid),put({descriptor,Key},D),#{ok => true};
        Error -> result(Error)
    end;
command(#{<<"op">> := <<"unpublish">>,<<"source">> := Key}) -> result(parvi_audio:unpublish(get({source,Key})));
command(#{<<"op">> := <<"pause_source">>,<<"source">> := Key,<<"paused">> := B}) -> result(parvi_audio:pause(get({source,Key}),B));
command(#{<<"op">> := <<"push_source">>,<<"source">> := Key,<<"target_ns">> := Target,<<"value">> := Value,<<"frames">> := Frames}) ->
    D = get({descriptor,Key}),Sample = case maps:get(sample_format,D) of
        float32_le -> <<Value:32/little-float>>;
        pcm16_le -> <<(round(Value*32768)):16/little-signed>>
    end,
    PCM = binary:copy(Sample,Frames*maps:get(channel_count,D)),
    case parvi_audio:push(get({source,Key}),channel,#{playback_time => Target,channel_id => 0},PCM) of
        {ok,Replies} -> #{ok => true,deliveries => length([ok || {_,ok} <- Replies])};
        Error -> result(Error)
    end;
command(#{<<"op">> := <<"audio_contract">>,<<"direction">> := Direction,<<"peer">> := Peer,
          <<"source">> := Source,<<"contract">> := Id}) ->
    D = case Direction of <<"publish">> -> publish;<<"receive">> -> receive_audio end,
    result(parvi_audio_receiver:set_contract(D,Peer,Source,Id,1));
command(#{<<"op">> := <<"audio_clear_contract">>,<<"direction">> := Direction,<<"peer">> := Peer,<<"source">> := Source}) ->
    D = case Direction of <<"publish">> -> publish;<<"receive">> -> receive_audio end,
    result(parvi_audio_receiver:clear_contract(D,Peer,Source));
command(#{<<"op">> := <<"audio_subscribe">>,<<"peer">> := Peer,<<"source">> := Key}) -> result(parvi_audio_receiver:subscribe(Peer,Key,channel));
command(#{<<"op">> := <<"audio_play">>,<<"id">> := Id,<<"playing">> := B}) ->
    result(parvi_audio_receiver:playback(Id,case B of true -> start;false -> stop end));
command(#{<<"op">> := <<"audio_unsubscribe">>,<<"id">> := Id}) -> result(parvi_audio_receiver:stop(Id));
command(#{<<"op">> := <<"audio_gain">>,<<"id">> := Id,<<"gain">> := G}) -> result(parvi_audio_receiver:gain(Id,G)).
format(<<"float32_le">>) -> float32_le;
format(<<"pcm16_le">>) -> pcm16_le.
result(ok) -> #{ok => true};
result({ok,V}) -> #{ok => true,value => V};
result({error,R}) -> #{error => R}.

await_receiver(_,0) -> error(receiver_not_restarted);
await_receiver(Old,N) ->
    case whereis(parvi_audio_receiver) of
        New when is_pid(New),New=/=Old -> gen_server:call(New,snapshot),ok;
        _ -> receive after 10 -> await_receiver(Old,N-1) end
    end.
