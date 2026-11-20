%% Bounded observation only: never starts audio, changes consent or retimes PCM.
%% Separate from the automation Worker so manually controlled/CLI Devices expose
%% exactly the same diagnostic projection. Remote ingress reads the Handler cache.
-module(ba_audio_observer).
-behaviour(gen_server).
-export([start_link/0,init/1,handle_call/3,handle_cast/2,handle_info/2]).
start_link() -> gen_server:start_link(ba_session_scope:registration(?MODULE),?MODULE,[],[]).
init([]) ->
    Owner=ba_session_scope:whereis(ba_device_handler), monitor(process,Owner),self() ! sample,{ok,Owner}.
handle_call(_,_,S) -> {reply,{error,unsupported},S}.
handle_cast(_,S) -> {noreply,S}.
handle_info(sample,Owner) ->
    erlang:send_after(250,self(),sample),
    Flags=ba_audio_diagnostics:options(),
    try
        View=case lists:any(fun(V) -> V end,maps:values(Flags)) of
            true -> case ba_session_scope:whereis(ba_audio_receiver) of undefined -> #{};_ -> ba_audio_receiver:snapshot() end;
            false -> #{}
        end,
        Clock=case ba_audio_diagnostics:enabled(analysis) of true -> ba_session_clock:status();false -> #{} end,
        Owner ! {audio_observation,self(),View,ba_audio_diagnostics:snapshot(View,Clock),ba_audio_diagnostics:trace(View)}
    catch exit:_ -> ok end,
    {noreply,Owner};
handle_info({'DOWN',_,process,Owner,_},Owner) -> {stop,normal,Owner};
handle_info(_,S) -> {noreply,S}.
