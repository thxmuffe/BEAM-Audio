%% Bounded scheduled PCM summation. Every block keeps its own source target.
-module(parvi_audio_mix).
-export([new/2,add/3,remove/2,enable/3,gain/3,push/6,next_time/1,take/2,snapshot/1]).
new(Rate,Clock) -> #{rate => Rate,clock => Clock,streams => #{},cursor => undefined,clipped => 0}.
add(Id,Gain,#{streams := Items} = S) when map_size(Items)<16;is_map_key(Id,Items) ->
    S#{streams := Items#{Id => #{gain => Gain,enabled => false,blocks => []}}}.
remove(Id,S) -> S#{streams := maps:remove(Id,maps:get(streams,S))}.
enable(Id,Enabled,S) when is_boolean(Enabled) ->
    update(Id,fun(I) -> I#{enabled := Enabled,blocks := []} end,S).
gain(Id,G,S) when is_number(G),G>=0,G=<1 -> update(Id,fun(I) -> I#{gain := G} end,S).
update(Id,F,#{streams := Items} = S) -> S#{streams := Items#{Id := F(maps:get(Id,Items))}}.
push(Id,#{sample_rate := Rate,clock := Clock,channel_count := Channels,sample_format := Format} = D,
     #{playback_time := Target,frame_count := Frames},PCM,Now,#{rate := Rate,clock := Clock,streams := Items} = S) ->
    try
        true = is_integer(Target) andalso Target>Now andalso Target-Now=<1000000000,
        true = is_integer(Frames) andalso Frames>0 andalso Frames=<4096,
        true = Channels=:=1 orelse Channels=:=2,
        true = byte_size(PCM)=:=Frames*parvi_audio_packet:frame_bytes(D),
        I = maps:get(Id,Items),true = maps:get(enabled,I),Blocks = maps:get(blocks,I),
        true = length(Blocks)<32,
        Start = (Target*Rate+500000000) div 1000000000,End = Start+Frames,
        Cursor = maps:get(cursor,S),true = Cursor=:=undefined orelse Start>=Cursor,
        true = lists:all(fun({T,Samples}) -> End=<T orelse Start>=T+length(Samples) end,Blocks),
        Samples = stereo(samples(PCM,Format),Channels),true = length(Samples)=:=Frames,
        true = lists:all(fun({L,R}) -> abs(L)=<16 andalso abs(R)=<16 end,Samples),
        {ok,S#{streams := Items#{Id := I#{blocks := lists:keysort(1,[{Start,Samples}|Blocks])}}}}
    catch _:_ -> {error,invalid_late_or_full,S} end;
push(_,_,_,_,_,S) -> {error,unsupported_mix_format_or_clock,S}.
next_time(#{streams := Items,rate := Rate}) ->
    Starts = [T || #{enabled := true,blocks := Blocks} <- maps:values(Items),{T,_} <- Blocks],
    case Starts of [] -> none;_ -> lists:min(Starts)*1000000000 div Rate end.
take(Max,#{streams := Items,rate := Rate} = S) when Max>0,Max=<2048 ->
    case next_time(S) of
        none -> empty;
        _ ->
            Start = lists:min([T || #{enabled := true,blocks := Bs} <- maps:values(Items),{T,_} <- Bs]),
            End = lists:max([T+length(B) || #{enabled := true,blocks := Bs} <- maps:values(Items),{T,B} <- Bs]),
            Count = min(Max,End-Start),Stop = Start+Count,
            Contributions = [contribution(Start,Count,I) || I <- maps:values(Items),maps:get(enabled,I)],
            Mixed = lists:foldl(fun(Frames,Acc) ->
                lists:zipwith(fun({L,R},{A,B}) -> {L+A,R+B} end,Frames,Acc)
            end,lists:duplicate(Count,{0.0,0.0}),Contributions),
            Clips = length([X || {L,R}=X <- Mixed,abs(L)>1 orelse abs(R)>1]),
            PCM = iolist_to_binary([<<(limit(L)):32/little-float,(limit(R)):32/little-float>> || {L,R} <- Mixed]),
            Trimmed = maps:map(fun(_,I) -> I#{blocks := trim(Stop,maps:get(blocks,I))} end,Items),
            Header = #{playback_time => Start*1000000000 div Rate,frame_count => Count,channel_id => 0},
            {Header,PCM,S#{streams := Trimmed,cursor := Stop,clipped := maps:get(clipped,S)+Clips}}
    end.
contribution(Start,Count,#{gain := G,blocks := Blocks}) ->
    Values = maps:from_list([{T+Offset,{L*G,R*G}} || {T,B} <- Blocks,
        {Offset,{L,R}} <- lists:zip(lists:seq(0,length(B)-1),B),T+Offset>=Start,T+Offset<Start+Count]),
    [maps:get(N,Values,{0.0,0.0}) || N <- lists:seq(Start,Start+Count-1)].
trim(Stop,Blocks) ->
    [{max(T,Stop),case T<Stop of true -> lists:nthtail(Stop-T,B);false -> B end}
        || {T,B} <- Blocks,T+length(B)>Stop].
limit(V) -> max(-1.0,min(1.0,V)).
samples(PCM,float32_le) -> [V || <<V:32/little-float>> <= PCM];
samples(PCM,pcm16_le) -> [V/32768 || <<V:16/little-signed>> <= PCM];
samples(PCM,pcm24_le) -> [V/8388608 || <<V:24/little-signed>> <= PCM];
samples(PCM,pcm32_le) -> [V/2147483648 || <<V:32/little-signed>> <= PCM].
stereo(S,1) -> [{V,V} || V <- S];
stereo([],2) -> [];
stereo([L,R|Rest],2) -> [{L,R}|stereo(Rest,2)].
snapshot(S) -> #{streams => map_size(maps:get(streams,S)),clipped_frames => maps:get(clipped,S),
    queued_blocks => lists:sum([length(maps:get(blocks,I)) || I <- maps:values(maps:get(streams,S))])}.
