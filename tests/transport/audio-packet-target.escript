#!/usr/bin/env escript
%% Actual pinned ExWebRTC sender and ExRTP wire codec, no network or device.
main(_) ->
    Root = filename:dirname(filename:dirname(filename:dirname(filename:absname(escript:script_name())))),
    Paths = ["builds/intermediates/tools/elixir/lib/*/ebin",
             "builds/intermediates/BeamTransport/dev/lib/*/ebin",
             "builds/intermediates/erlang/default/lib/ba_core/ebin"],
    [code:add_patha(P) || Pattern <- Paths,P <- filelib:wildcard(filename:join(Root,Pattern))],
    {ok,_} = application:ensure_all_started(elixir),
    Now = 1793820000000000000,
    Sender0 = 'Elixir.ExWebRTC.RTPSender':new(nil,123,124,[]),
    Sender = Sender0#{codec := #{payload_type => 111,clock_rate => 48000}},
    Targets = [Now+1000000000,Now+1020375000,Now+1712345678],
    {Wires,_} = lists:mapfoldl(fun({T,Seq},S) ->
        Target = ba_audio_rtp_time:quantize(T),
        {ok,P} = ba_audio_rtp_time:packet(<<1,2,3>>,#{continuous => true,
            presentation => #{target_output_time_ns => Target}},Seq,false),
        {Wire,Next} = 'Elixir.ExWebRTC.RTPSender':send_packet(S,P,false),
        {{Target,Wire},Next}
    end,Sender,lists:zip(Targets,lists:seq(1,3))),
    %% Drop the middle packet and reverse arrival. No side anchors are provided.
    [begin
        <<_:32,Timestamp:32,_/binary>> = Wire,
        {ok,P} = 'Elixir.ExRTP.Packet':decode(Wire),
        Timestamp = maps:get(timestamp,P),
        <<1,2,3>> = maps:get(payload,P),
        {ok,Target} = ba_audio_rtp_time:decode(Timestamp,Now)
    end || {Target,Wire} <- [lists:last(Wires),hd(Wires)]],
    io:format("Pinned ExWebRTC sender preserves each assigned target in RTP bytes; reordered/lost neighbours do not affect decoding.~n").
