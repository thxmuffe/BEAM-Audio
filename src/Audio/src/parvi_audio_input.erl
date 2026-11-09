%% Portable input policy, run inside an adapter's existing OTP worker.
%% The adapter supplies PCM, its descriptor and local monotonic nanoseconds.
%% This module owns no process, port or platform-specific clock representation.
-module(parvi_audio_input).
-export([new/0, ready/0, open/2, captured/3, status/1,
         source_monitor/2, stop/1, failed/2, close/1]).

new() -> #{state => stopped, source => undefined, frames => 0,
           blocks => 0, skipped_frames => 0, send_errors => 0}.
ready() ->
    case parvi_clock:now() of
        {ok, _} -> ok;
        {error, _} -> {error, <<"Clock is not synchronized yet. Try broadcast again shortly.">>}
    end.

open(Name, Descriptor0) ->
    Descriptor = Descriptor0#{clock => parvi_clock:id()},
    Handler = parvi_audio_stream_handler:default(),
    Frame = Handler:frame_bytes(Descriptor),
    true = Frame =< Handler:max_payload_bytes(channel),
    {ok, Source} = parvi_audio:publish(#{name => Name, profiles => #{channel => Descriptor}}, self()),
    Ref = monitor(process, Source),
    event(audio_started, <<"[Audio] ", Name/binary, " is available for subscription.">>),
    (new())#{state := running, source := Source, source_monitor => Ref,
             handler => Handler,name => Name, descriptor => Descriptor}.

captured(<<>>, _, S) -> S;
captured(PCM, Mono, #{descriptor := #{sample_format := Encoding} = Descriptor, handler := Handler} = S) ->
    Frame = Handler:frame_bytes(Descriptor),
    true = byte_size(PCM) rem Frame =:= 0,
    Frames = byte_size(PCM) div Frame,
    Levels = parvi_audio_meter:levels(parvi_audio_meter:accumulate(Encoding, PCM, parvi_audio_meter:new())),
    Next = S#{frames := maps:get(frames, S) + Frames, meter => Levels,
              last_capture_ms => erlang:monotonic_time(millisecond)},
    %% Use one immutable mapping for both times, including an active clock slew.
    case parvi_clock:presentation([Mono, erlang:monotonic_time(nanosecond)]) of
        {ok, #{times := [UTC,Now],clock := Clock,offset_ms := Offset}} when Clock=:=map_get(clock,Descriptor) ->
            Lead = Offset * 1000000,
            case UTC + Lead > Now of
                true ->
                    {Blocks, Errors} = send_blocks(PCM, UTC + Lead, 0, S),
                    Next#{state := running, blocks := maps:get(blocks, S) + Blocks,
                          send_errors := maps:get(send_errors, S) + Errors};
                false -> Next#{skipped_frames := maps:get(skipped_frames, S) + Frames}
            end;
        {ok,#{clock := Clock}} ->
            ok = parvi_audio:rebind(maps:get(source,S),Clock),
            captured(PCM,Mono,S#{descriptor := Descriptor#{clock := Clock}});
        _ -> Next#{state := waiting_for_clock, skipped_frames := maps:get(skipped_frames, S) + Frames}
    end.

send_blocks(<<>>, _, _, _) -> {0, 0};
send_blocks(PCM, Time, Offset, #{descriptor := #{sample_rate := Rate} = Descriptor,
                                source := Source, handler := Handler} = S) ->
    Frame = Handler:frame_bytes(Descriptor),
    Max = min(Handler:max_payload_bytes(channel),4096*Frame),
    Size = min(byte_size(PCM), (Max div Frame) * Frame),
    <<Block:Size/binary, Rest/binary>> = PCM,
    {ok, Results} = parvi_audio:push(Source, channel,
        #{playback_time => Time + Offset * 1000000000 div Rate, channel_id => 0}, Block),
    Errors = length([R || {_, {error, _} = R} <- Results]),
    {N, E} = send_blocks(Rest, Time, Offset + Size div Frame, S), {N + 1, E + Errors}.

status(S) ->
    Public = maps:without([source, source_monitor, handler, last_capture_ms], S),
    case maps:find(last_capture_ms, S) of
        {ok, Last} ->
            case erlang:monotonic_time(millisecond) - Last > 250 of
                true -> Public#{meter => parvi_audio_meter:levels(parvi_audio_meter:new())};
                false -> Public
            end;
        error -> Public
    end.
source_monitor(Ref, S) -> maps:get(source_monitor, S, undefined) =:= Ref.
stop(S) ->
    close(S), event(audio_stopped, <<"[Audio] Broadcast stopped.">>), new().
failed(Text, S) ->
    close(S), event(audio_error, <<"[Audio] ", Text/binary>>),
    (new())#{state := error, error => Text}.
close(S) ->
    case maps:get(source_monitor, S, undefined) of undefined -> ok; Ref -> demonitor(Ref, [flush]) end,
    case maps:get(source, S) of
        undefined -> ok;
        Source -> try parvi_audio:unpublish(Source) catch exit:_ -> ok end
    end.
event(Kind,Text) ->
    Level = case Kind of audio_error -> error;_ -> info end,
    logger:log(Level,"~ts",[Text],#{domain => [parvi,audio],event => Kind}),
    parvi_events:notify(audio_input).
