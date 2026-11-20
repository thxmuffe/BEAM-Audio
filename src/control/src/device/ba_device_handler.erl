%% This Device's capabilities and its audio Worker. No network ingress,
%% arbitrary modules or hardware.
-module(ba_device_handler).
-behaviour(gen_server).
-export([start_link/0,capabilities/0,capabilities/1,status/0,audio_changed/0]).
-export([init/1,handle_continue/2,handle_call/3,handle_cast/2,handle_info/2]).
-ifdef(TEST).
-export([no_worker_speaker/1]).
-endif.

start_link() -> gen_server:start_link(ba_session_scope:registration(?MODULE),?MODULE,[],[]).
audio_changed() -> gen_server:cast(ba_session_scope:ref(?MODULE),audio_changed),ok.
capabilities() -> gen_server:call(ba_session_scope:ref(?MODULE),capabilities,100).
capabilities(false) -> capabilities();
capabilities(true) -> gen_server:call(ba_session_scope:ref(?MODULE),capability_metrics,100).
status() -> gen_server:call(ba_session_scope:ref(?MODULE),status).
init([]) ->
    case ba_settings:app(audio_automation,false) of true -> self() ! audio_worker;false -> ok end,
    {ok,#{instance => fresh(),revision => 0},{continue,resolve_label}}.

%% Resolving the label's OS metadata (a registry query on Windows, plus first
%% module loads) can exceed the 100 ms capability call. Do it once at start,
%% so a peer's first capability read after authorization gets its answer.
handle_continue(resolve_label,#{instance := Instance}=S) ->
    _=ba_device_label:local(Instance),{noreply,S}.

handle_call(capability_metrics,_,S) -> {reply,capability_metrics(S),S};
handle_call(capabilities,_,S) -> {reply,capability_snapshot(S),S};
handle_call(status,_,S) ->
    {reply,#{capabilities => capability_snapshot(S),monitor => capability_metrics(S),audio => app_audio(S)},S};
handle_call(_,_,S) -> {reply,{error,unsupported},S}.
handle_cast(audio_changed,#{audio_worker := P}=S) -> ba_device_audio:changed(P),{noreply,changed(S)};
handle_cast(_,S) -> {noreply,S}.

handle_info({audio_observation,P,View,Diagnostics,Trace},S) ->
    case P=:=ba_session_scope:whereis(ba_audio_observer) of
        true -> {noreply,S#{audio_view => View,audio_diagnostics => Diagnostics,audio_trace => Trace,audio_observed_at => erlang:monotonic_time(millisecond)}};
        false -> {noreply,S}
    end;
handle_info(audio_worker,S) ->
    case ba_session_scope:whereis(ba_device_worker_sup) of
        undefined -> erlang:send_after(50,self(),audio_worker),{noreply,S};
        _ ->
            case supervisor:start_child(ba_session_scope:ref(ba_device_worker_sup),#{id => audio,start => {ba_device_audio,start_link,[self()]},restart => temporary}) of
                {ok,P} -> monitor(process,P),{noreply,S#{audio_worker => P}};
                {error,{already_started,P}} -> {noreply,S#{audio_worker => P}};
                _ -> erlang:send_after(250,self(),audio_worker),{noreply,S}
            end
    end;
handle_info({audio_state,P,Audio},#{audio_worker := P}=S) ->
    {noreply,changed(S#{audio => Audio})};
handle_info({'DOWN',_,process,P,_},#{audio_worker := P}=S) ->
    erlang:send_after(250,self(),audio_worker),{noreply,maps:remove(audio_worker,S#{audio => #{},audio_diagnostics => #{}})};
handle_info(_,S) -> {noreply,S}.

changed(S) -> S#{revision := maps:get(revision,S)+1}.
capability_snapshot(#{instance := Instance,revision := Revision}=S) ->
    Base=#{<<"device_name">> => ba_device_label:local(Instance),<<"instance">> => Instance,<<"revision">> => Revision},
    case ba_settings:app(audio_automation,false) orelse maps:is_key(audio_view,S) of
        false -> Base;
        true -> Base#{<<"audio">> => maps:from_list([{atom_to_binary(K),
            #{<<"consent">> => B,<<"state">> => atom_to_binary(maps:get(state,maps:get(K,maps:get(audio,S,#{}),#{}),waiting)),
              <<"available">> => B andalso lists:member(maps:get(state,maps:get(K,maps:get(audio,S,#{}),#{}),waiting),[ready,running])}} || {K,B} <- maps:to_list(ba_app_session:consent()),
               %% The capabilities wire contract has exactly these three; local gates
               %% (calibration, DSP) are not part of what Devices tell each other.
               lists:member(K,[speaker,microphone,broadcast])])}
    end.

%% Without the audio automation Worker nothing subscribes or plays here (e.g.
%% Windows until its PCM binding is connected, or an Inspector). Say so instead
%% of looking idle-but-ready; manually driven mixers still report their streams.
no_worker_speaker(Mixer) ->
    case {maps:get(streams,Mixer,0)>0,ba_settings:app(audio_automation,false)} of
        {true,_} -> #{state => running};
        {false,true} -> #{state => ready};
        {false,false} ->
            case maps:get(speaker,ba_app_session:consent(),false) of
                true -> #{state => unsupported,error => <<"Playback is not available on this Device yet.">>};
                false -> #{state => unsupported}
            end
    end.
%% What the app window shows: the Worker's rows, or the explicit no-Worker speaker.
app_audio(S) ->
    Audio=maps:get(audio,S,#{}),
    case maps:is_key(speaker,Audio) orelse ba_settings:app(audio_automation,false) of
        true -> Audio;
        false -> Audio#{speaker => no_worker_speaker(maps:get(mixer,maps:get(audio_view,S,#{}),#{}))}
    end.
capability_metrics(S) ->
    View=maps:get(audio_view,S,#{}),
    Mixer=maps:get(mixer,View,#{}),
    Speaker=maps:get(speaker,maps:get(audio,S,#{}),no_worker_speaker(Mixer)),
    OutputMeter=maps:get(output_meter,Mixer,#{}),
    Meter=case map_size(OutputMeter) of 0 -> maps:get(receive_meter,View,#{});_ -> OutputMeter end,
    Audio=(maps:get(audio,S,#{}))#{speaker => Speaker#{meter => Meter}},
    MetricsState=S#{audio => Audio},
    Named0=capability_snapshot(MetricsState),
    Named=case ba_audio_diagnostics:enabled(meters) of
        true -> Named0#{<<"audio_meters">> => ba_audio_diagnostics:meters(View)};false -> Named0
    end,
    SampleAge=case maps:find(audio_observed_at,S) of
        {ok,At} -> #{<<"diagnostics.age_ms">> => max(0,erlang:monotonic_time(millisecond)-At)};
        error -> #{}
    end,
    Base=case ba_audio_diagnostics:enabled(analysis) of
        true -> Named#{<<"audio_diagnostics">> => maps:merge(maps:merge(maps:get(audio_diagnostics,S,#{}),SampleAge),diagnostic_flags())};
        false -> Named#{<<"audio_diagnostics">> => diagnostic_flags()}
    end,
    WithTrace=case ba_audio_diagnostics:enabled(analysis) of
        true -> Base#{<<"audio_trace">> => maps:get(audio_trace,S,#{})};false -> Base
    end,
    case maps:find(<<"audio">>,WithTrace) of
        error -> WithTrace;
        {ok,WireAudio} -> WithTrace#{<<"audio">> := maps:map(fun(K,Entry) ->
            %% Every consent key, including calibration and DSP; K came from atom_to_binary above.
            Key=binary_to_existing_atom(K),
            Row=maps:get(Key,Audio,#{}),
            EntryMeter=case ba_audio_diagnostics:enabled(meters) of true -> maps:get(meter,Row,#{});false -> #{} end,
            Counts=maps:from_list([{Wire,V} || {Field,Wire} <- [{blocks,<<"blocks">>},{frames,<<"frames">>},{dropped_callbacks,<<"dropped">>}],
                {ok,V} <- [maps:find(Field,Row)],is_integer(V),V>=0]),
            Error=case maps:get(error,Row,undefined) of
                Reason when is_atom(Reason),Reason=/=undefined -> #{<<"error">> => atom_to_binary(Reason)};
                TextError when is_binary(TextError),byte_size(TextError)=<256 -> #{<<"error">> => TextError};
                _ -> #{}
            end,
            maps:merge(maps:merge(Entry,Error),maps:merge(Counts,maps:with([<<"peak_db">>,<<"rms_db">>,<<"meter_age_ms">>,<<"meter_stage">>],EntryMeter)))
        end,WireAudio)}
    end.

diagnostic_flags() -> #{<<"diagnostics.meters">> => ba_audio_diagnostics:enabled(meters),
    <<"diagnostics.analysis">> => ba_audio_diagnostics:enabled(analysis)}.
fresh() -> binary:encode_hex(crypto:strong_rand_bytes(16)).
