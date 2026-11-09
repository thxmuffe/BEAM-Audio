%% Scheduled PCM summation. Queues hold binaries; targets remain source-owned.
-module(ba_audio_mix).
-export([new/2,add/3,remove/2,enable/3,gain/3,push/6,next_time/1,take/2,snapshot/1]).
-define(MAX_BYTES,33554432).
-define(MAX_BLOCKS,8192).
new(Rate,Clock) -> #{rate => Rate,clock => Clock,streams => #{},cursor => undefined,
    queued_bytes => 0,queued_blocks => 0,clipped => 0}.
add(Id,G,S) ->
    Cleared = remove(Id,S),Items = maps:get(streams,Cleared),true = map_size(Items)<16,
    Cleared#{streams := Items#{Id => #{gain => G,enabled => false,blocks => gb_trees:empty(),bytes => 0,count => 0}}}.
remove(Id,#{streams := Items}=S) ->
    case maps:take(Id,Items) of
        {I,Rest} -> S#{streams := Rest,queued_bytes := maps:get(queued_bytes,S)-maps:get(bytes,I),
            queued_blocks := maps:get(queued_blocks,S)-maps:get(count,I)};
        error -> S
    end.
enable(Id,B,#{streams := Items}=S) when is_boolean(B) ->
    I = maps:get(Id,Items),S#{streams := Items#{Id := I#{enabled := B,blocks := gb_trees:empty(),bytes := 0,count := 0}},
        queued_bytes := maps:get(queued_bytes,S)-maps:get(bytes,I),queued_blocks := maps:get(queued_blocks,S)-maps:get(count,I)}.
gain(Id,G,#{streams := Items}=S) when is_number(G),G>=0,G=<1 ->
    S#{streams := Items#{Id := (maps:get(Id,Items))#{gain := G}}}.
push(Id,#{sample_rate := Rate,clock := Clock,channel_count := C,sample_format := F}=D,
     #{playback_time := Target,frame_count := Frames},PCM,Now,#{rate := Rate,clock := Clock,streams := Items}=S) ->
    try
        true = is_integer(Target) andalso Target>Now andalso Target-Now=<31000000000,
        true = is_integer(Frames) andalso Frames>0 andalso Frames=<4096,
        true = C=:=1 orelse C=:=2,true = byte_size(PCM)=:=Frames*ba_audio_packet:frame_bytes(D),
        I = maps:get(Id,Items),true = maps:get(enabled,I),Tree = maps:get(blocks,I),
        true = maps:get(count,I)<4096 andalso maps:get(queued_blocks,S)<?MAX_BLOCKS,
        Start = (Target*Rate+500000000) div 1000000000,End = Start+Frames,
        Cursor = maps:get(cursor,S),true = Cursor=:=undefined orelse Start>=Cursor,
        true = lists:all(fun({T,{N,_}}) -> End=<T orelse Start>=T+N end,gb_trees:to_list(Tree)),
        Values = stereo(samples(PCM,F),C),true = length(Values)=:=Frames,
        true = lists:all(fun({L,R}) -> abs(L)=<16 andalso abs(R)=<16 end,Values),
        Bin = iolist_to_binary([<<L:32/little-float,R:32/little-float>> || {L,R} <- Values]),Size = byte_size(Bin),
        true = maps:get(queued_bytes,S)+Size=< ?MAX_BYTES,
        Next = I#{blocks := gb_trees:insert(Start,{Frames,Bin},Tree),bytes := maps:get(bytes,I)+Size,count := maps:get(count,I)+1},
        {ok,S#{streams := Items#{Id := Next},queued_bytes := maps:get(queued_bytes,S)+Size,queued_blocks := maps:get(queued_blocks,S)+1}}
    catch _:_ -> {error,invalid_late_or_full,S} end;
push(_,_,_,_,_,S) -> {error,unsupported_mix_format_or_clock,S}.
active(S) -> [I || #{enabled := true,count := N}=I <- maps:values(maps:get(streams,S)),N>0].
next_time(#{rate := Rate}=S) ->
    case active(S) of [] -> none;Inputs ->
        lists:min([T || I <- Inputs,{T,_} <- [gb_trees:smallest(maps:get(blocks,I))]])*1000000000 div Rate end.
take(Max,#{rate := Rate,streams := Items}=S) when Max>0,Max=<2048 ->
    case active(S) of
        [] -> empty;
        Inputs ->
            Start = lists:min([T || I <- Inputs,{T,_} <- [gb_trees:smallest(maps:get(blocks,I))]]),
            End = lists:max([T+N || I <- Inputs,{T,{N,_}} <- [gb_trees:largest(maps:get(blocks,I))]]),
            Count = min(Max,End-Start),Stop = Start+Count,
            Mixed = lists:foldl(fun(I,Acc) -> lists:zipwith(fun({L,R},{A,B}) -> {L+A,R+B} end,
                contribution(Start,Stop,I),Acc) end,lists:duplicate(Count,{0.0,0.0}),Inputs),
            Clips = length([ok || {L,R} <- Mixed,abs(L)>1 orelse abs(R)>1]),
            PCM = iolist_to_binary([<<(limit(L)):32/little-float,(limit(R)):32/little-float>> || {L,R} <- Mixed]),
            Trimmed = maps:map(fun(_,I) -> trim(Stop,I) end,Items),
            Bytes = lists:sum([maps:get(bytes,I) || I <- maps:values(Trimmed)]),
            Blocks = lists:sum([maps:get(count,I) || I <- maps:values(Trimmed)]),
            {#{playback_time => Start*1000000000 div Rate,frame_count => Count,channel_id => 0},PCM,
             S#{streams := Trimmed,cursor := Stop,queued_bytes := Bytes,queued_blocks := Blocks,clipped := maps:get(clipped,S)+Clips}}
    end.
contribution(Start,Stop,#{gain := G,blocks := Tree}) ->
    Values = collect(Start,Stop,G,gb_trees:iterator(Tree),#{}),
    [maps:get(N,Values,{0.0,0.0}) || N <- lists:seq(Start,Stop-1)].
collect(Start,Stop,G,Iterator,Values) ->
    case gb_trees:next(Iterator) of
        none -> Values;
        {T,_,_} when T>=Stop -> Values;
        {T,{N,PCM},Next} ->
            First = max(T,Start),Last = min(T+N,Stop),
            Added = case Last>First of
                false -> Values;
                true ->
                    Part = binary:part(PCM,(First-T)*8,(Last-First)*8),
                    Pairs = [{L*G,R*G} || <<L:32/little-float,R:32/little-float>> <= Part],
                    maps:merge(Values,maps:from_list(lists:zip(lists:seq(First,Last-1),Pairs)))
            end,collect(Start,Stop,G,Next,Added)
    end.
trim(Stop,#{blocks := Tree,count := Count}=I) when Count>0 ->
    {T,{N,PCM}} = gb_trees:smallest(Tree),
    case T<Stop of
        false -> I;
        true ->
            {_,_,Rest} = gb_trees:take_smallest(Tree),Used = min(N,Stop-T),Bytes = Used*8,
            case Used=:=N of
                true -> trim(Stop,I#{blocks := Rest,count := Count-1,bytes := maps:get(bytes,I)-Bytes});
                false -> I#{blocks := gb_trees:insert(Stop,{N-Used,binary:part(PCM,Bytes,byte_size(PCM)-Bytes)},Rest),
                    bytes := maps:get(bytes,I)-Bytes}
            end
    end;
trim(_,I) -> I.
limit(V) -> max(-1.0,min(1.0,V)).
samples(PCM,float32_le) -> [V || <<V:32/little-float>> <= PCM];
samples(PCM,pcm16_le) -> [V/32768 || <<V:16/little-signed>> <= PCM];
samples(PCM,pcm24_le) -> [V/8388608 || <<V:24/little-signed>> <= PCM];
samples(PCM,pcm32_le) -> [V/2147483648 || <<V:32/little-signed>> <= PCM].
stereo(S,1) -> [{V,V} || V <- S];
stereo([],2) -> [];
stereo([L,R|Rest],2) -> [{L,R}|stereo(Rest,2)].
snapshot(S) -> #{streams => map_size(maps:get(streams,S)),clipped_frames => maps:get(clipped,S),
    queued_blocks => maps:get(queued_blocks,S),queued_bytes => maps:get(queued_bytes,S),max_bytes => ?MAX_BYTES}.
