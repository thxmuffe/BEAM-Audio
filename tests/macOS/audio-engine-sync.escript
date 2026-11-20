#!/usr/bin/env escript
%%! -noshell
%% Audio engine milestone 1 measurement (macOS): one sender capturing a test
%% tone and two receivers playing it through the default output, over loopback
%% UDP with SRTP and FLAC, all on one Session clock (this host's Erlang clock).
%%
%% Reports each engine's own scheduling error: how far the device position is
%% from where the Session timeline says it should be, using the OS callback
%% timestamps and reported device latency. This is software scheduling
%% evidence, not physical speaker timing. Receivers are silent unless --audible.
%%
%% Usage: escript tests/macOS/audio-engine-sync.escript [--audible] [--seconds N] [--source system]
%% --source system sends this Mac's own output (System Audio Recording
%% permission) instead of the tone; with --audible you hear it twice more,
%% 200 ms later, through both receivers.
-mode(compile).

main(Args) ->
    Root=filename:absname(filename:join([filename:dirname(escript:script_name()),"..",".."])),
    Engine=filename:join(Root,"builds/CLI/ba_audio_engine"),
    case filelib:is_regular(Engine) of
        true -> ok;
        false -> io:format("UNAVAILABLE: build the engine with scripts/platforms/macOS/build-engine.sh~n"),halt(2)
    end,
    [code:add_patha(P) || P <- filelib:wildcard(filename:join(Root,"builds/intermediates/control/default/lib/*/ebin"))],
    logger:set_primary_config(level,warning),
    process_flag(trap_exit,true),
    Gain=case lists:member("--audible",Args) of true -> 0.1;false -> 0.0 end,
    Seconds=option("--seconds",Args,20),
    Source=list_to_binary(option("--source",Args,"tone")),
    %% Every engine maps its host clock to this Erlang node's system time.
    Clock=fun(Monotonic) -> Monotonic+erlang:time_offset(nanosecond) end,
    Start=fun() -> {ok,P}=ba_audio_engine:start_link(#{executable => Engine,clock => Clock}),P end,
    [Sender,R1,R2]=[Start() || _ <- [1,2,3]],
    Key=crypto:strong_rand_bytes(30),Ssrc=rand:uniform(16#7fffffff),Rate=48000,Delay=200,
    Ports=[ba_audio_engine:udp_port(R) || R <- [R1,R2]],
    {ok,#{input_rate := InRate}}=ba_audio_engine:command(Sender,#{op => start_capture,source => Source,ssrc => Ssrc,
        rate => Rate,key => Key,peers => [[<<"127.0.0.1">>,P] || P <- Ports]}),
    Anchor=receive {ba_audio_engine,Sender,#{event := <<"capture_started">>,anchor_ns := A}} -> A
           after 3000 -> io:format("FAIL: capture never started~n"),halt(1) end,
    OutRates=[begin {ok,#{output_rate := O}}=ba_audio_engine:command(R,#{op => start_speaker,ssrc => Ssrc,rate => Rate,
        anchor_ns => Anchor,delay_ms => Delay,key => Key,gain => Gain}),O end || R <- [R1,R2]],
    io:format("~ts ~p Hz capture -> ~p Hz stream -> outputs ~p Hz; delay ~p ms; ~p s; ~s~n",
        [Source,InRate,Rate,OutRates,Delay,Seconds,case Gain>0 of true -> "audible";false -> "silent"end]),
    io:format("~6s  ~-24s ~-36s ~-36s~n",["t s","sender error us (mean/max)","receiver 1 error us / missing late","receiver 2 error us / missing late"]),
    %% The first window includes start-up positioning; judge the rest.
    timer:sleep(2000),[ba_audio_engine:command(E,#{op => status}) || E <- [Sender,R1,R2]],
    Rows=[sample(T,Sender,R1,R2) || T <- lists:seq(2,Seconds,2)],
    Final=[begin {ok,S}=ba_audio_engine:command(R,#{op => status}),hd(maps:get(speakers,S)) end || R <- [R1,R2]],
    {ok,SenderFinal}=ba_audio_engine:command(Sender,#{op => status}),
    io:format("Sender: ~p~nReceivers: ~p~n",[maps:without([error],maps:get(capture,SenderFinal)),[maps:without([error],F) || F <- Final]]),
    WorstMean=lists:max([M || {_,Ms} <- Rows,M <- Ms]),
    Faults=lists:sum([maps:get(K,F) || F <- Final,K <- [late,rejected,jumps]]),
    case WorstMean<100.0 andalso Faults=:=0 of
        true -> io:format("PASS: worst mean scheduling error ~.1f us; no late, rejected or re-positioned audio~n",[WorstMean]),halt(0);
        false -> io:format("FAIL: worst mean scheduling error ~.1f us; late+rejected+jumps ~p~n",[WorstMean,Faults]),halt(1)
    end.

sample(T,Sender,R1,R2) ->
    timer:sleep(2000),
    {ok,#{capture := C}}=ba_audio_engine:command(Sender,#{op => status}),
    Rs=[begin {ok,#{speakers := [S]}}=ba_audio_engine:command(R,#{op => status}),S end || R <- [R1,R2]],
    Err=fun(#{error := #{mean_us := M,max_us := X}}) -> io_lib:format("~8.1f / ~8.1f",[float(M),float(X)]) end,
    io:format("~6B  ~-24s ~-36s ~-36s~n",[T+2,Err(C)|[[Err(S),io_lib:format("  ~B ~B",[maps:get(missing_frames,S),maps:get(late,S)])] || S <- Rs]]),
    {T,[maps:get(mean_us,maps:get(error,X)) || X <- [C|Rs]]}.

option(Name,[Name,Value|_],Default) when is_integer(Default) -> list_to_integer(Value);
option(Name,[Name,Value|_],_) -> Value;
option(Name,[_|T],Default) -> option(Name,T,Default);
option(_,[],Default) -> Default.
