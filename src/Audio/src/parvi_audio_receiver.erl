%% Runtime-owned source catalogue and one received-audio meter; no device I/O.
-module(parvi_audio_receiver).
-behaviour(gen_server).
-export([snapshot/0, refresh/0, suspend/0, resume/0, subscribe/2, stop/0, playback/1, minimum_playout_delay/1, control_output/1, start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).
-define(GROUP, {parvi, audio, sources}).

snapshot() -> call(snapshot).
refresh() -> call(refresh).
suspend() -> call(suspend).
resume() -> call(resume).
subscribe(Id, Profile) -> call({subscribe, Id, Profile}).
stop() -> call(stop).
playback(Action) -> call({playback, Action}).
minimum_playout_delay(Delay) -> control_output({minimum_delay,Delay}).
control_output(Command) -> call({output_control,Command}).
call(Request) ->
    case parvi_audio_sup:ensure_started() of
        ok -> gen_server:call(?MODULE,Request);
        Error -> Error
    end.
start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).
init([]) ->
    ok = net_kernel:monitor_nodes(true),
    connect_sources(),
    {ok,_} = parvi_events:subscribe(),
    erlang:send_after(1000,self(),restore_subscription),
    {Watch, Sources} = parvi_audio:watch_sources(),
    S = #{handler => parvi_audio_stream_handler:default(), watch => Watch, offers => #{},
          requests => gen_server:reqids_new(), receive_state => idle(),
          output => undefined, playback => #{state => <<"stopped">>},
          intent => parvi_audio_subscription_intent:load(),suspended => false,
          resume_after => undefined,retry_at => erlang:monotonic_time(millisecond)},
    {ok, discover(Sources, S)}.
idle() -> #{state => stopped, session => undefined, packets => 0, frames => 0, bytes => 0}.

handle_call(Request, From, S) -> changed(handle_call_event(Request, From, S), S).

handle_call_event(refresh,_,S) -> connect_sources(), {reply,ok,S};
handle_call_event(forget_subscription,_,S) ->
    ok = parvi_audio_subscription_intent:save(undefined),
    {reply,ok,disconnect(S#{intent := undefined})};
handle_call_event(suspend,_,S) ->
    {reply,ok,disconnect(S#{suspended := true})};
handle_call_event(resume,_,S) ->
    After = erlang:monotonic_time(nanosecond),
    _ = try parvi_clock:resync() catch exit:_ -> unavailable end,
    connect_sources(),
    {reply,ok,disconnect(S#{suspended := false,resume_after := After,retry_at := erlang:monotonic_time(millisecond)})};
handle_call_event(snapshot, _, #{offers := Offers, receive_state := R, handler := Handler} = S) ->
    Rows = [public_offer(Pid, Offer) || {Pid, #{name := _} = Offer} <- maps:to_list(Offers)],
    {reply, #{offers => lists:sort(fun(A,B) -> maps:get(id,A) < maps:get(id,B) end, Rows),
              receiver => public_receive_with_intent(R,S), backend => Handler:info(), handler => maps:get(id,Handler:info()),
              native_statistics => maps:get(native_statistics,S,null),
              playback => (maps:get(playback,S))#{available => Handler:output_available()}}, S};
handle_call_event({playback, start}, _, #{output := undefined,
                                 handler := Handler, receive_state := #{profile := channel, descriptor := D, session := Session}} = S) ->
    case Handler:start_output(self(), D#{session => Session}) of
        {ok, Pid} ->
            Ref = monitor(process, Pid),
            {reply, ok, remember_playback(true,S#{output := {Pid,Ref}, playback := #{state => <<"starting">>}})};
        Error -> {reply, Error, S}
    end;
handle_call_event({playback, stop}, _, S) ->
    {reply, ok, remember_playback(false,stop_output(S))};
handle_call_event({playback, _}, _, S) ->
    {reply, {error, <<"Subscribe to a mono or stereo channel stream before playback.">>}, S};
handle_call_event({output_control, Command}, _,
            #{handler := Handler, receive_state := #{state := active, session := Session}} = S) ->
    {reply,Handler:output_control(Session,Command),S};
handle_call_event({output_control, _}, _, S) ->
    {reply,{error,<<"Subscribe to audio before controlling its output.">>},S};
handle_call_event({subscribe, Id, Profile}, _, #{offers := Offers, receive_state := R} = S) ->
    Matches = [{Pid,O} || {Pid, #{id := I, profiles := Ps} = O} <- maps:to_list(Offers),
                          I =:= Id, maps:is_key(Profile, Ps)],
    case {maps:get(session, R), Matches} of
        {undefined, [{Source, Offer}]} ->
            Next = begin_subscription(Source,Offer,Profile,remember_source(Source,Offer,Profile,S)),
            {reply,ok,Next};
        {undefined, _} -> {reply, {error, source_unavailable}, S};
        _ -> {reply, {error, <<"Stop the current subscription before selecting another.">>}, S}
    end;
handle_call_event(stop, _, #{receive_state := R} = S) ->
    close(R),
    ok = parvi_audio_subscription_intent:save(undefined),
    {reply, ok, (stop_output(S))#{receive_state := idle(),intent := undefined}};
handle_call_event(_, _, S) -> {reply, {error, unsupported_request}, S}.
handle_cast(_, S) -> {noreply, S}.

handle_info(Message, S) -> changed(handle_info_event(Message, S), S).

handle_info_event(restore_subscription,S) ->
    erlang:send_after(1000,self(),restore_subscription),
    {noreply,restore_subscription(S)};
handle_info_event({parvi_changed,policy},S) ->
    {noreply,reconcile_policy(S)};
handle_info_event({nodeup,_},S) -> connect_sources(), {noreply,S};
handle_info_event({Watch, join, ?GROUP, Pids}, #{watch := Watch} = S) -> {noreply, discover(Pids, S)};
handle_info_event({Watch, leave, ?GROUP, Pids}, #{watch := Watch, offers := Offers} = S) ->
    {noreply, S#{offers := maps:without(Pids, Offers)}};
handle_info_event({parvi_audio, Session, Header, PCM},
            #{receive_state := #{session := Session, descriptor := D} = R, handler := Handler} = S) ->
    Levels = parvi_audio_meter:levels(parvi_audio_meter:accumulate(
        maps:get(sample_format, D), PCM, parvi_audio_meter:new())),
    Next = R#{packets := maps:get(packets,R) + 1, frames := maps:get(frames,R) + maps:get(frame_count,Header),
              bytes := maps:get(bytes,R) + byte_size(PCM), meter => Levels,
              last_packet => erlang:monotonic_time(millisecond)},
    case maps:get(output,S) of
        {Pid,_} -> Handler:push_output(Pid, Header, PCM);
        undefined -> ok
    end,
    {noreply, S#{receive_state := Next}};
handle_info_event({parvi_native_audio, Session, Stats}, #{receive_state := #{session := Session} = R} = S) ->
    Packets = maps:get(<<"packetsReceived">>,Stats,0),
    Meter = case {maps:get(<<"samplePeakDb">>,Stats,undefined), maps:get(<<"sampleRmsDb">>,Stats,undefined)} of
        {Peak, RMS} when is_number(Peak), is_number(RMS) ->
            #{<<"peak_db">> => Peak, <<"rms_db">> => RMS};
        _ -> #{}
    end,
    Next = R#{packets := Packets, bytes := maps:get(<<"bytesReceived">>,Stats,0),
        frames := maps:get(<<"totalSamplesReceived">>,Stats,0), meter => Meter},
    WithTime = case Packets > maps:get(packets,R) of
        true -> Next#{last_packet => erlang:monotonic_time(millisecond)}; false -> Next end,
    Report = recent_native_timing(native_timing(Stats),maps:get(native_statistics,S,#{})),
    {noreply,S#{receive_state := WithTime, native_statistics => Report}};
handle_info_event({parvi_audio_output, Pid, Status}, #{output := {Pid,_},playback := Previous} = S) ->
    case {maps:get(state,Status),maps:get(state,Previous)} of
        {<<"playing">>,Old} when Old =/= <<"playing">> ->
            parvi_chat:system(info,audio_playback,<<"[Audio] Playback started.">>,#{});
        _ -> ok
    end,
    {noreply, S#{playback := Status}};
handle_info_event({'DOWN', Ref, process, _, Reason}, #{output := {_,Ref}} = S) ->
    Text = <<"Playback stopped. Check the audio route and try Play again.">>,
    parvi_chat:system(error, audio_playback, <<"[Audio] ",Text/binary>>, #{reason => Reason}),
    {noreply, S#{output := undefined, playback := #{state => <<"error">>, error => Text}}};
handle_info_event({'DOWN', Ref, process, _, Reason}, #{receive_state := #{monitor := Ref}} = S) ->
    {noreply, failed({subscription_closed, Reason}, S)};
handle_info_event(Message, #{receive_state := R} = S) ->
    Response = case maps:find(pending, R) of
        {ok, Id} -> gen_statem:check_response(Message, Id);
        error -> no_reply
    end,
    case Response of
        no_reply -> {noreply, description(Message, S)};
        _ -> {noreply, response(Response, S)}
    end.

%% pg supplies offers once a publisher is directly connected. Ask existing
%% trusted neighbors for source PIDs, then reuse normal member authentication
%% for just those publishers; do not connect the entire cluster into a mesh.
connect_sources() ->
    case application:get_env(parvi,native_desk,false) of
        true -> spawn(fun() ->
            Members = [N || #{node := N} <- parvi_node_api:members()],
            Peers = nodes(),
            Sources = lists:flatmap(fun(Peer) ->
                try erpc:call(Peer,parvi_audio,sources,[],1000)
                catch _:_ -> [] end
            end,Peers),
            Targets = lists:usort([node(P) || P <- Sources,is_pid(P),node(P) =/= node(),
                not lists:member(node(P),Peers),lists:member(atom_to_binary(node(P)),Members)]),
            [parvi_cluster_desk:connect_member(atom_to_binary(N)) || N <- Targets]
        end), ok;
        false -> ok
    end.

discover(Pids, S) ->
    lists:foldl(fun(Pid, #{offers := Offers, requests := Requests} = Acc) ->
        case node(Pid) =/= node() andalso not maps:is_key(Pid, Offers) of
            true ->
                Id = integer_to_binary(erlang:unique_integer([positive, monotonic])),
                Next = gen_server:send_request(Pid, describe, Pid, Requests),
                Acc#{offers := Offers#{Pid => #{id => Id}}, requests := Next};
            false -> Acc
        end
    end, S, Pids).

description(Message, #{requests := Requests, offers := Offers} = S) ->
    case gen_server:check_response(Message, Requests, true) of
        {{reply, #{name := Name, profiles := Profiles} = Description}, Pid, Next} ->
            case maps:find(Pid, Offers) of
                {ok, Offer} ->
                    Supported = maps:filter(fun(P,D) ->
                        Selected = parvi_audio_stream_handler:for_descriptor(D),
                        Selected:validate_descriptor(P,D) =:= ok end, Profiles),
                    S#{requests := Next, offers := Offers#{Pid := Offer#{name => Name,source_key => maps:get(source_key,Description,Name), profiles => Supported}}};
                error -> S#{requests := Next}
            end;
        {_, Pid, Next} -> S#{requests := Next, offers := maps:remove(Pid, Offers)};
        _ -> S
    end.

response({reply, {ok, Session, Descriptor}}, #{receive_state := #{state := opening, session := Session} = R} = S) ->
    try parvi_audio:listen(Session, self()) of
        ok ->
            Pending = gen_statem:send_request(Session, ready),
            S#{receive_state := R#{state := activating, pending := Pending, descriptor => Descriptor}}
    catch exit:Reason -> failed(Reason, S) end;
response({reply, ok}, #{receive_state := #{state := activating} = R} = S) ->
    parvi_chat:system(info,audio_subscription,
        <<"[Audio] Subscribed to: ",(maps:get(source_name,R))/binary,".">>,
        #{source_id => maps:get(source_id,R),source_name => maps:get(source_name,R)}),
    restore_playback(S#{receive_state := maps:remove(pending, R#{state := active})});
response({reply, {error, Reason}}, S) -> failed(Reason, S);
response({error, Reason}, S) -> failed(Reason, S);
response(_, S) -> failed(invalid_subscription_reply, S).


begin_subscription(Source,Offer,Profile,S) ->
    Handler = parvi_audio_stream_handler:for_descriptor(maps:get(Profile,maps:get(profiles,Offer))),
    {ok,Session} = parvi_audio_sup:start_session({receiver,self(),Handler}),
    Monitor = monitor(process,Session),
    Pending = gen_statem:send_request(Session,{open,Source,#{profile => Profile,selector => all}}),
    Next = (idle())#{state := opening,session := Session,monitor => Monitor,pending => Pending,
        source_id => maps:get(id,Offer),source_name => maps:get(name,Offer),profile => Profile},
    (maps:remove(native_statistics,S))#{receive_state := Next,handler := Handler}.
remember_source(Source,Offer,Profile,S) ->
    case parvi_cluster_trust:snapshot() of
        #{<<"cluster">> := Cluster} ->
            I = parvi_audio_subscription_intent:new(Cluster,atom_to_binary(node(Source)),Offer,Profile),
            ok = parvi_audio_subscription_intent:save(I), S#{intent := I};
        _ -> S
    end.
remember_playback(Playing,#{intent := I} = S) when is_map(I) ->
    Next = I#{playing := Playing},
    ok = parvi_audio_subscription_intent:save(Next), S#{intent := Next};
remember_playback(_,S) -> S.
disconnect(#{receive_state := R} = S) ->
    close(R), (maps:remove(native_statistics,stop_output(S)))#{receive_state := idle()}.
reconcile_policy(#{intent := #{cluster := Cluster}} = S) ->
    case parvi_cluster_trust:snapshot() of
        #{<<"cluster">> := Cluster} = Policy ->
            case source_admitted(maps:get(intent,S),Policy) of
                true -> S;
                false -> disconnect(S)
            end;
        _ -> ok = parvi_audio_subscription_intent:save(undefined),
             disconnect(S#{intent := undefined})
    end;
reconcile_policy(S) -> S.
source_admitted(#{node := Node},#{<<"members">> := Members}) ->
    lists:any(fun(M) -> maps:get(<<"node">>,M) =:= Node end,maps:values(Members)).

restore_subscription(#{suspended := true} = S) -> S;
restore_subscription(#{intent := #{cluster := Cluster} = I,receive_state := #{session := undefined},
                       offers := Offers,retry_at := Retry,resume_after := After} = S) ->
    case parvi_cluster_trust:snapshot() of
        #{<<"cluster">> := Cluster} = Policy ->
            Ready = source_admitted(I,Policy) andalso erlang:monotonic_time(millisecond) >= Retry andalso
                parvi_audio_subscription_intent:clock_ready(parvi_clock:status(),After),
            Matches = [{P,O} || {P,#{name := _} = O} <- maps:to_list(Offers),
                parvi_audio_subscription_intent:matches(I,atom_to_binary(node(P)),O)],
            case {Ready,Matches} of
                {true,[{Source,Offer}]} ->
                    Handler = parvi_audio_stream_handler:for_descriptor(
                        maps:get(maps:get(profile,I),maps:get(profiles,Offer))),
                    Supported = Handler =/= parvi_audio_stream_handler_webrtc orelse
                        (Handler:output_available() andalso
                         maps:get(presentation_schedule_execution,parvi_audio_engine:info(),false)),
                    case Supported of
                        true -> begin_subscription(Source,Offer,maps:get(profile,I),S);
                        false -> S
                    end;
                {_,[]} when Ready ->
                    connect_sources(), S#{retry_at := erlang:monotonic_time(millisecond)+5000};
                _ -> S
            end;
        undefined -> S;
        _ -> reconcile_policy(S)
    end;
restore_subscription(S) -> S.
restore_playback(#{intent := #{playing := true},handler := Handler,
                   receive_state := #{descriptor := D,session := Session}} = S) ->
    case Handler:start_output(self(),D#{session => Session}) of
        {ok,Pid} -> S#{output := {Pid,monitor(process,Pid)},playback := #{state => <<"starting">>}};
        {error,Reason} -> failed({playback_restore_failed,Reason},S)
    end;
restore_playback(S) -> S.
public_receive_with_intent(R,#{intent := I,suspended := Suspended}) ->
    View = public_receive(R),
    case {maps:get(session,R),I} of
        {undefined,#{name := Name}} -> View#{saved_subscription => true,source_name => Name,
            state => case Suspended of true -> <<"suspended">>; false -> <<"waiting_for_source">> end};
        _ -> View#{saved_subscription => is_map(I)}
    end.

public_offer(Pid, #{id := Id, name := Name, profiles := Profiles}) ->
    #{id => Id, name => Name, node => atom_to_binary(node(Pid)), profiles =>
        [#{id => atom_to_binary(P), sample_rate => maps:get(sample_rate,D),
           channels => maps:get(channel_count,D), sample_format => atom_to_binary(maps:get(sample_format,D))}
         || {P,D} <- lists:sort(maps:to_list(Profiles))]}.
public_receive(R) ->
    Now = erlang:monotonic_time(millisecond),
    Native = maps:get(stream_handler,maps:get(descriptor,R,#{}),legacy_webrtc) =:= webrtc_audio_opus,
    {MeterAge,DataAge} = case Native of true -> {2000,2500}; false -> {250,500} end,
    Age = case maps:find(last_packet,R) of {ok,T} -> Now-T; error -> undefined end,
    Meter = case Age =/= undefined andalso Age =< MeterAge of
        true -> maps:get(meter,R,#{}); false -> parvi_audio_meter:levels(parvi_audio_meter:new())
    end,
    State = case {maps:get(state,R), Age} of
        {active, undefined} -> waiting_for_audio;
        {active, A} when A > DataAge -> no_data;
        {active, _} -> receiving;
        {Other, _} -> Other
    end,
    #{state => atom_to_binary(State), packets => maps:get(packets,R), frames => maps:get(frames,R),
      bytes => maps:get(bytes,R), peak_db => maps:get(<<"peak_db">>,Meter,-96.0),
      meter_available => maps:is_key(<<"peak_db">>,Meter) andalso Age =/= undefined andalso Age =< MeterAge,
      rms_db => maps:get(<<"rms_db">>,Meter,-96.0), source_id => maps:get(source_id,R,null),
      source_name => maps:get(source_name,R,null), error => maps:get(error,R,null),
      subscribed => maps:get(session,R) =/= undefined}.
failed(Reason, #{receive_state := R} = S) ->
    close(R), Text = case maps:get(intent,S,undefined) of
        I when is_map(I) -> <<"Audio connection lost. Waiting to restore the saved subscription.">>;
        _ -> <<"Audio subscription ended. Check the source and connection, then subscribe again.">>
    end,
    parvi_chat:system(error, audio_subscription, <<"[Audio] ", Text/binary>>, #{reason => Reason}),
    (stop_output(S))#{retry_at := erlang:monotonic_time(millisecond)+5000,
        receive_state := (maps:without([monitor,pending,descriptor],R))#{state := error, session := undefined, error => Text}}.
stop_output(#{output := Output, handler := Handler} = S) ->
    case Output of
        {Pid,Ref} -> demonitor(Ref,[flush]), Handler:stop_output(Pid);
        undefined -> ok
    end,
    S#{output := undefined, playback := #{state => <<"stopped">>}}.
close(R) ->
    case maps:find(monitor,R) of {ok,Ref} -> demonitor(Ref,[flush]); error -> ok end,
    case maps:get(session,R) of
        undefined -> ok;
        Session -> try parvi_audio:close(Session) catch exit:_ -> ok end
    end.
%% W3C cumulative jitter-buffer seconds / emitted samples: session mean,
%% not packet jitter, current buffer depth or end-to-end capture latency.
native_timing(#{<<"jitterBufferDelay">> := Delay, <<"jitterBufferEmittedCount">> := Count} = Stats)
        when is_number(Delay), Delay >= 0, is_integer(Count), Count > 0 ->
    Stats#{<<"mean_jitter_buffer_delay_ms">> => 1000 * Delay / Count};
native_timing(Stats) -> Stats.
%% Difference of cumulative counters: average residence time for samples
%% emitted since the previous report, not current queue depth or total latency.
recent_native_timing(#{<<"jitterBufferDelay">> := Delay, <<"jitterBufferEmittedCount">> := Count} = Stats,
                     #{<<"jitterBufferDelay">> := PreviousDelay, <<"jitterBufferEmittedCount">> := PreviousCount})
        when is_number(Delay), is_number(PreviousDelay), Delay >= PreviousDelay,
             is_integer(Count), is_integer(PreviousCount), Count > PreviousCount ->
    Stats#{<<"recent_jitter_buffer_delay_ms">> => 1000*(Delay-PreviousDelay)/(Count-PreviousCount)};
recent_native_timing(Stats,_) -> Stats.
terminate(_, #{receive_state := R} = S) -> stop_output(S), close(R).

changed({reply,Reply,Next}, Old) ->
    notify_changed(Old,Next), {reply,Reply,Next};
changed({noreply,Next}, Old) ->
    notify_changed(Old,Next), {noreply,Next};
changed(Result, _) -> Result.
notify_changed(Old,Next) ->
    View = fun(S) -> S end,
    case View(Old) =:= View(Next) of
        true -> ok; false -> parvi_events:notify(audio_receive)
    end.
