%% Owns independent durable subscriptions and local publication permissions.
%% Media is native AAC only: this process routes catalogue, subscription and
%% SDP/ICE control; audio never passes through it.
-module(ba_audio_receiver).
-behaviour(gen_server).
-export([start_link/0,snapshot/0,refresh/0,refresh/1,subscribe/2,subscribe/3,stop/0,stop/1,
         playback/1,playback/2,gain/2,set_contract/5,clear_contract/3,register_source/1,
         suspend/0,resume/0,network_changed/0]).
-export([init/1,handle_call/3,handle_cast/2,handle_info/2,terminate/2,format_status/1]).
start_link() -> gen_server:start_link(ba_session_scope:registration(?MODULE),?MODULE,[],[]).
snapshot() -> call(snapshot).
refresh() -> call(refresh).
refresh(Peer) -> call({refresh,Peer}).
subscribe({Peer,Source},Profile) -> subscribe(Peer,Source,Profile);
subscribe(_,_) -> {error,publisher_and_source_required}.
subscribe(Peer,Source,Profile) -> call({subscribe,Peer,Source,Profile}).
stop() -> call(stop).
stop(Id) -> call({stop,Id}).
playback(_) -> {error,subscription_id_required}.
playback(Id,Action) -> call({playback,Id,Action}).
gain(Id,G) -> call({gain,Id,G}).
set_contract(Direction,Peer,Source,Id,Revision) -> call({contract,Direction,Peer,Source,Id,Revision}).
clear_contract(Direction,Peer,Source) -> call({clear_contract,Direction,Peer,Source}).
register_source(Pid) -> call({register,Pid}).
suspend() -> call(suspend).
resume() -> call(resume).
network_changed() -> gen_server:cast(ba_session_scope:ref(?MODULE),network_changed).
call(Request) ->
    case ba_audio_sup:ensure_started() of ok -> gen_server:call(ba_session_scope:ref(?MODULE),Request,10000);Error -> Error end.
init([]) ->
    Items = ba_subscription:load(),
    erlang:send_after(250,self(),tick),
    Control = ba_session_scope:whereis(ba_buffee_control),true = is_pid(Control),monitor(process,Control),
    self() ! catalog_bootstrap,
    {ok,#{sources => #{},offers => #{},subscriptions => maps:map(fun(_,I) -> waiting(I) end,Items),
          providers => #{},catalogs => #{},contracts => #{},control => Control,
          suspended => false,resume_after => undefined,rejected => 0,poll_at => now_ms()+5000}}.
waiting(I) -> #{intent => I,state => waiting_for_source,session => undefined,retry_at => now_ms()}.
handle_call(snapshot,_,S) ->
    View = maps:map(fun(_,R) ->
        I = maps:get(intent,R),(maps:merge(I,maps:with([state,source_paused,error,mix_ready],R)))#{transport => transport_status(R)}
    end,maps:get(subscriptions,S)),
    Rows = [O#{device => Peer,source_key => Key} || {{Peer,Key},O} <- maps:to_list(maps:get(offers,S))],
    {reply,#{subscriptions => View,offers => Rows,publications => map_size(maps:get(sources,S)),
             providers => map_size(maps:get(providers,S)),
             provider_status => [#{peer => maps:get(peer,maps:get(context,R)),source => maps:get(source,R),
                 transport => transport_status(R)} || R <- maps:values(maps:get(providers,S))],
             rejected => maps:get(rejected,S),suspended => maps:get(suspended,S),diagnostics => ba_diagnostics:view(S)},S};
handle_call({register,Pid},_,#{sources := Sources} = S) when is_pid(Pid),node(Pid)=:=node(),map_size(Sources)<16 ->
    try
        Offer = gen_server:call(Pid,describe,100),Key = maps:get(source_key,Offer),
        {Pub,_}=ba_device_store:identity(),
        case publication_allowed(binary:encode_hex(Pub),Key) of
            true -> ok;false -> throw(on_air_required)
        end,
        false = maps:is_key(Key,Sources),
        _ = ba_audio_stream_protocol:offer(Key,maps:get(incarnation,Offer),Offer),
        Ref = monitor(process,Pid),Entry = #{pid => Pid,monitor => Ref,offer => Offer},
        {reply,ok,announce_catalog(S#{sources := Sources#{Key => Entry}})}
    catch throw:on_air_required -> {reply,{error,on_air_required},S};
          _:_ -> {reply,{error,invalid_or_duplicate_publication},S} end;
handle_call({contract,Direction,Peer,Key,Id,Revision},_,#{contracts := Contracts} = S) ->
    try
        true = Direction=:=publish orelse Direction=:=receive_audio,
        true = ba_buffee_job:hex(Peer,64),true = ba_buffee_job:hex(Id,32),
        true = is_binary(Key) andalso byte_size(Key)>0 andalso byte_size(Key)=<128,
        true = is_integer(Revision) andalso Revision>0 andalso Revision=<9007199254740991,
        ContractKey = {Direction,Peer,Key},
        true = maps:is_key(ContractKey,Contracts) orelse map_size(Contracts)<32,
        Contract = #{id => Id,revision => Revision},
        case maps:get(ContractKey,Contracts,undefined) of
            Contract -> {reply,ok,S};
            #{id := Id,revision := Old} when Revision<Old -> {reply,{error,stale_contract},S};
            _ -> Next = stop_contract(ContractKey,S),
                 {reply,ok,Next#{contracts := Contracts#{ContractKey => Contract}}}
        end
    catch _:_ -> {reply,{error,invalid_contract},S} end;
handle_call({clear_contract,Direction,Peer,Key},_,S) when Direction=:=publish;Direction=:=receive_audio ->
    C = {Direction,Peer,Key},Next = stop_contract(C,S),
    {reply,ok,Next#{contracts := maps:remove(C,maps:get(contracts,S))}};
handle_call({refresh,Peer},_,S) ->
    {Reply,Next} = catalog(Peer,S),{reply,Reply,Next};
handle_call(refresh,_,S) -> {reply,ok,refresh_all(S)};
handle_call({subscribe,Peer,Key,channel},_,#{subscriptions := Items,offers := Offers} = S) when map_size(Items)<16 ->
    Existing = lists:any(fun(R) -> I = maps:get(intent,R),maps:get(device,I)=:=Peer andalso maps:get(source_key,I)=:=Key end,maps:values(Items)),
    case {Existing,maps:find({Peer,Key},Offers),context(Peer)} of
        {false,{ok,O},{ok,#{buffee := Buffee}}} ->
            I = ba_subscription:new(Buffee,Peer,O,channel),Id = maps:get(id,I),
            Next = persist(S#{subscriptions := Items#{Id => waiting(I)}}),
            {reply,{ok,Id},restore_one(Id,false,Next)};
        {true,_,_} -> {reply,{error,already_subscribed},S};
        _ -> {reply,{error,source_or_session_unavailable},S}
    end;
handle_call({stop,Id},_,S) -> {reply,ok,unsubscribe(Id,S)};
handle_call(stop,_,S) ->
    Next = lists:foldl(fun unsubscribe/2,S,maps:keys(maps:get(subscriptions,S))),{reply,ok,Next};
handle_call(forget_subscription,From,S) -> handle_call(stop,From,S);
handle_call({playback,Id,Action},_,#{subscriptions := Items} = S) when Action=:=start;Action=:=stop ->
    case maps:find(Id,Items) of
        {ok,#{intent := I} = R} ->
            Playing = Action=:=start,
            Result = case {Playing,maps:get(state,R),maps:get(source_paused,R,false)} of
                {false,_,_} -> disable_output(Id,R),{ok,R#{mix_ready => false}};
                {true,active,false} -> enable_output(Id,R);
                {true,active,true} -> {ok,R#{mix_ready => false}};
                _ -> {error,subscription_not_active}
            end,
            case Result of
                {ok,NextR} -> {reply,ok,persist(S#{subscriptions := Items#{Id := NextR#{intent := I#{playing := Playing}}}})};
                Error -> {reply,Error,S}
            end;
        error -> {reply,{error,unknown_subscription},S}
    end;
handle_call({gain,Id,G},_,#{subscriptions := Items} = S) when is_number(G),G>=0,G=<1 ->
    case maps:find(Id,Items) of
        {ok,#{intent := I} = R} ->
            case maps:get(mix_ready,R,false) of true -> output_gain(Id,G,R);false -> ok end,
            {reply,ok,persist(S#{subscriptions := Items#{Id := R#{intent := I#{gain := G}}}})};
        error -> {reply,{error,unknown_subscription},S}
    end;
handle_call(suspend,_,S) -> {reply,ok,disconnect_all(S#{suspended := true})};
handle_call(resume,_,S) ->
    resync_clock(resume),
    {reply,ok,disconnect_all(S#{suspended := false,resume_after := erlang:monotonic_time(nanosecond)})};
handle_call(_,_,S) -> {reply,{error,unsupported_request},S}.
%% A path notification is a discovery hint, not proof that authenticated media
%% or the reference clock failed. Their own monitors, leases and sample freshness
%% fence real failures. Restarting acquisition here creates repeated audio bursts.
handle_cast(network_changed,S) -> {noreply,S#{poll_at => now_ms()}};
handle_cast(_,S) -> {noreply,S}.
handle_info(catalog_bootstrap,S) -> {noreply,refresh_all(S)};
%% A gossiped "on air" note from a Device that may not be a neighbour: read its
%% catalogue (saying hello first if needed). Playback consent decides the rest.
handle_info({on_air_announced,Peer},#{offers := Offers}=S) ->
    case lists:any(fun({P,_}) -> P=:=Peer end,maps:keys(Offers)) of
        true -> {noreply,S};
        false ->
            %% Announced sources count as known for a minute, so the read follows
            %% the hello if there was no relationship yet.
            Wanted = (maps:get(wanted,S,#{}))#{Peer => now_ms()+60000},
            {_,Next} = catalog(Peer,S#{wanted => Wanted}),{noreply,Next}
    end;
handle_info({audio_session_up,#{peer := Peer,session := Session}},S) ->
    %% Only a source this Device already knows is re-read; others announce.
    case {lists:member(Peer,known_sources(S)),context(Peer)} of
        {true,{ok,#{session := Session}}} ->
            Cs=maps:get(catalogs,S),
            Pending=case maps:find(Peer,Cs) of
                {ok,#{session := Session}} -> Cs;
                _ -> maps:remove(Peer,Cs)
            end,
            {_,Next}=catalog(Peer,S#{catalogs := Pending}),{noreply,Next};
        _ -> {noreply,S}
    end;
handle_info(tick,S) ->
    erlang:send_after(250,self(),tick),
    Catalogs = maps:filter(fun(_,C) -> maps:get(deadline,C)>now_ms() end,maps:get(catalogs,S)),
    %% Push (catalog.changed) is the path; this re-read of known sources every
    %% 5 s repairs a lost notice and keeps those relationships alive while
    %% listening. Each read is independent.
    Polled = case now_ms()>=maps:get(poll_at,S,0) of
        true -> refresh_all(S#{catalogs := Catalogs,poll_at => now_ms()+5000});
        false -> S#{catalogs := Catalogs}
    end,
    Next = announce_new(Polled),
    Final = lists:foldl(fun(Id,Acc) -> restore_one(Id,true,Acc) end,Next,maps:keys(maps:get(subscriptions,Next))),
    Recovered=case maps:get(suspended,Final) of
        true -> Final;
        false -> Final#{subscriptions := maps:map(fun(Id,R) ->
            case maps:get(state,R)=:=active andalso not maps:get(mix_ready,R,false) of
                true -> start_playback(Id,R);false -> R
            end end,maps:get(subscriptions,Final))}
    end,
    {noreply,Recovered};
handle_info({buffee_audio,Context,Id,P},S) ->
    try
        #{peer := Peer,session := Session,buffee := Buffee,deadline := Deadline} = Context,
        true = now_ms()<Deadline,
        {ok,#{session := Session,buffee := Buffee}} = context(Peer),
        incoming(Context,Id,P,S)
    of Next -> {noreply,Next}
    catch _:_ ->
        %% Signalling for an attempt that already ended (e.g. after a setup
        %% timeout) is expected noise; keep it apart from invalid control.
        case P of
            #{<<"kind">> := <<"signal.",_/binary>>} ->
                {noreply,ba_diagnostics:count(stale_media_signal,S#{rejected := maps:get(rejected,S)+1})};
            _ -> {noreply,reject(S)}
        end
    end;
handle_info({audio_session_renewed,#{peer := Peer,session := Session,deadline := Until}},S) ->
    %% The owner emits this while the peer's authenticated packets keep
    %% arriving; a later packet may already have moved the deadline further.
    case context(Peer) of
        {ok,#{session := Session,deadline := Current}} when Current>=Until ->
            Subs = maps:map(fun(Id,R) -> renew_media(Id,Peer,Session,Until,R) end,maps:get(subscriptions,S)),
            Providers = maps:map(fun(_,R) -> renew_media(undefined,Peer,Session,Until,R) end,maps:get(providers,S)),
            {noreply,S#{subscriptions := Subs,providers := Providers}};
        _ -> {noreply,reject(S)}
    end;
handle_info({audio_session_down,Peer,Session},S) ->
    Next = stop_matching(fun(R) -> scoped(Peer,Session,R) end,S),
    Offers = maps:filter(fun({P,_},_) -> P=/=Peer end,maps:get(offers,Next)),
    {noreply,Next#{offers := Offers,catalogs := maps:remove(Peer,maps:get(catalogs,Next))}};
handle_info({audio_signal,Pid,P},S) ->
    case transport(Pid,S) of
        {Side,Key,R} ->
            Id = case Side of provider -> maps:get(subscription,R);receiver -> Key end,
            case wire(R,Id,maps:merge(binding(R),P)) of
                ok -> {noreply,S};
                _ ->
                    Next = case Side of receiver -> put_sub(Key,close_receiver(Key,R),S);provider -> close_provider(Key,R,S) end,
                    {noreply,Next}
            end;
        none -> {noreply,reject(S)}
    end;
handle_info({audio_transport,Pid,open},S) ->
    case transport(Pid,S) of
        {receiver,Id,R} -> {noreply,put_sub(Id,start_playback(Id,R#{state := active}),S)};
        {provider,_,_} -> {noreply,S};
        none -> {noreply,reject(S)}
    end;
handle_info({publication_rebound,Pid,Offer},#{sources := Sources}=S) ->
    case [{K,E} || {K,#{pid := P}=E} <- maps:to_list(Sources),P=:=Pid] of
        [{Key,E}] ->
            Next = lists:foldl(fun({K,#{source := Source}=R},Acc) ->
                case Source=:=Key of
                    true -> _ = wire(R,maps:get(subscription,R),(binding(R))#{<<"kind">> => <<"close">>}),close_provider(K,R,Acc);
                    false -> Acc
                end
            end,S,maps:to_list(maps:get(providers,S))),
            {noreply,announce_catalog(Next#{sources := Sources#{Key := E#{offer := Offer}}})};
        _ -> {noreply,reject(S)}
    end;
handle_info({publication_state,Pid,B},#{sources := Sources} = S) ->
    Matches = [{Key,E} || {Key,#{pid := P}=E} <- maps:to_list(Sources),P=:=Pid],
    case Matches of
        [{Key,#{offer := O}=E}] ->
            [wire(R,maps:get(subscription,R),(binding(R))#{<<"kind">> => <<"state">>,<<"paused">> => B})
                || R <- maps:values(maps:get(providers,S)),maps:get(source,R)=:=Key],
            Providers = maps:map(fun(_,R) ->
                case maps:get(source,R)=:=Key of true -> R#{paused := B};false -> R end
            end,maps:get(providers,S)),
            Next=S#{sources := Sources#{Key := E#{offer := O#{paused := B}}},providers := Providers},
            {noreply,case maps:get(paused,O)=:=B of true -> Next;false -> announce_catalog(Next) end};
        _ -> {noreply,reject(S)}
    end;
handle_info({'DOWN',_,process,Pid,_},#{control := Pid} = S) -> {stop,normal,S};
handle_info({'DOWN',Ref,process,Pid,Reason},S) ->
    Next = case transport(Pid,S) of
        {receiver,Id,R} ->
            Failure = ba_diagnostics:reason(Reason),
            case Failure of
                normal -> put_sub(Id,closed(Id,R),S);
                _ -> put_sub(Id,(closed(Id,R))#{error => Failure},ba_diagnostics:count(Failure,S))
            end;
        {provider,Key,R} -> _ = wire(R,maps:get(subscription,R),(binding(R))#{<<"kind">> => <<"close">>}),
            Removed = S#{providers := maps:remove(Key,maps:get(providers,S))},
            case Reason of normal -> Removed;_ -> ba_diagnostics:count(Reason,Removed) end;
        none -> S
    end,
    Sources = maps:filter(fun(_,#{monitor := M}) -> M=/=Ref end,maps:get(sources,Next)),
    Updated=Next#{sources := Sources},
    {noreply,case map_size(Sources)=:=map_size(maps:get(sources,Next)) of
        true -> Updated;false -> announce_catalog(Updated)
    end};
handle_info(_,S) -> {noreply,S}.

incoming(#{peer := Peer},_,#{<<"kind">> := <<"catalog.changed">>},#{catalogs := Cs}=S) ->
    %% Changes arriving while a snapshot is in flight request one more snapshot,
    %% rather than losing the event or launching overlapping reads.
    case maps:find(Peer,Cs) of
        {ok,#{deadline := Deadline}=C} ->
            case now_ms()<Deadline of
                true -> S#{catalogs := Cs#{Peer := C#{dirty => true}}};
                false -> {_,Next}=catalog(Peer,S#{catalogs := maps:remove(Peer,Cs)}),Next
            end;
        error -> {_,Next}=catalog(Peer,S),Next
    end;
incoming(#{peer := Peer} = Context,Id,#{<<"kind">> := <<"catalog.read">>},S) ->
    maps:foreach(fun(Key,#{offer := Offer}) ->
        send(Peer,Id,ba_audio_stream_protocol:offer(Key,maps:get(incarnation,Offer),Offer))
    end,maps:get(sources,S)),send(Peer,Id,#{<<"kind">> => <<"catalog.end">>}),_ = Context,S;
incoming(#{peer := Peer,session := Session},Id,#{<<"kind">> := <<"catalog.offer">>} = P,#{catalogs := Cs} = S) ->
    #{id := Id,session := Session,deadline := Deadline,offers := Offers} = C = maps:get(Peer,Cs),
    true = now_ms()<Deadline,true = map_size(Offers)<16,
    Key = maps:get(<<"source">>,P),false = maps:is_key(Key,Offers),
    true=publication_allowed(Peer,Key),
    D = ba_audio_stream_protocol:descriptor(P),
    O = #{name => maps:get(<<"name">>,P),source_key => Key,incarnation => maps:get(<<"incarnation">>,P),
          paused => maps:get(<<"paused">>,P),profiles => #{channel => D}},
    S#{catalogs := Cs#{Peer := C#{offers := Offers#{Key => O}}}};
incoming(#{peer := Peer,session := Session},Id,#{<<"kind">> := <<"catalog.end">>},#{catalogs := Cs,offers := Old} = S) ->
    #{id := Id,session := Session,deadline := Deadline,offers := Offers}=C = maps:get(Peer,Cs),true = now_ms()<Deadline,
    Kept = maps:filter(fun({P,_},_) -> P=/=Peer end,Old),
    Added = maps:from_list([{{Peer,K},O} || {K,O} <- maps:to_list(Offers)]),
    Next=S#{catalogs := maps:remove(Peer,Cs),offers := maps:merge(Kept,Added)},
    case maps:get(dirty,C,false) of
        true -> {_,Refreshed}=catalog(Peer,Next),Refreshed;
        false -> Next
    end;
incoming(Context,Id,#{<<"kind">> := <<"subscribe">>} = P,S) -> admit(Context,Id,P,S);
incoming(Context,Id,#{<<"kind">> := <<"accepted">>} = P,S) ->
    R = maps:get(Id,maps:get(subscriptions,S)),matches(Context,P,R),opening = maps:get(state,R),
    undefined = maps:get(session,R),
    case ba_audio_sup:start_session(worker(receiver,Context,Id,R)) of
        {ok,Pid} ->
            Ref = monitor(process,Pid),
            put_sub(Id,R#{session := Pid,monitor => Ref,source_paused => maps:get(<<"paused">>,P)},S);
        _ ->
            wire(R,Id,(binding(R))#{<<"kind">> => <<"close">>}),
            put_sub(Id,(closed(Id,R))#{error => transport_unavailable},S)
    end;
incoming(Context,Id,#{<<"kind">> := <<"rejected">>} = P,S) ->
    R = maps:get(Id,maps:get(subscriptions,S)),matches(Context,P,R),
    put_sub(Id,(close_receiver(Id,R))#{error => maps:get(<<"reason">>,P)},S);
incoming(Context,Id,#{<<"kind">> := Kind} = P,S) ->
    {Side,Key,R} = bound_transport(Context,Id,P,S),
    case Kind of
        <<"close">> ->
            case Side of
                receiver -> put_sub(Key,close_receiver(Key,R),S);
                provider -> close_provider(Key,R,S)
            end;
        <<"state">> when Side=:=receiver ->
            B = maps:get(<<"paused">>,P),
            _ = disable_output(Key,R),
            put_sub(Key,start_playback(Key,R#{source_paused => B,mix_ready => false}),S);
        _ when Kind=:= <<"signal.offer">>;Kind=:= <<"signal.answer">>;Kind=:= <<"signal.candidate">> ->
            gen_server:cast(maps:get(session,R),{signal,P}),S
    end.

admit(#{peer := Peer,session := Session} = Context,Id,P,#{sources := Sources,providers := Providers} = S) ->
    Key = maps:get(<<"source">>,P),Inc = maps:get(<<"incarnation">>,P),Attempt = maps:get(<<"attempt">>,P),
    ProviderKey = {Peer,Session,Id},
    case maps:find(ProviderKey,Providers) of
        {ok,R} -> matches(Context,P,R),wire(R,Id,(binding(R))#{<<"kind">> => <<"accepted">>,<<"paused">> => maps:get(paused,R)}),S;
        error ->
            Reason = case {maps:find(Key,Sources),maps:find({publish,Peer,Key},maps:get(contracts,S)),map_size(Providers)<16} of
                {{ok,#{offer := #{incarnation := Inc}}},{ok,#{id := C,revision := V}},true}
                    when C=:=map_get(<<"contract">>,P),V=:=map_get(<<"revision">>,P) -> ok;
                {_,_,false} -> <<"capacity">>;
                {{ok,_},_,_} -> <<"contract">>;
                _ -> <<"unavailable">>
            end,
            R0 = #{source => Key,incarnation => Inc,attempt => Attempt,context => Context,subscription => Id},
            case Reason of
                ok ->
                    #{pid := Source,offer := #{paused := Paused,profiles := #{channel := D}}} = maps:get(Key,Sources),
                    R = R0#{descriptor => D,paused => Paused},
                    case ba_audio_sup:start_session((worker(provider,Context,Id,R))#{source_pid => Source}) of
                        {ok,Pid} ->
                            Attached = try gen_server:call(Source,{attach,Pid},100) catch exit:_ -> unavailable end,
                            case Attached of
                                ok ->
                                    Ref = monitor(process,Pid),
                                    wire(R,Id,(binding(R))#{<<"kind">> => <<"accepted">>,<<"paused">> => Paused}),
                                    S#{providers := Providers#{ProviderKey => R#{session => Pid,monitor => Ref}}};
                                _ ->
                                    stop_worker(Pid),
                                    wire(R,Id,(binding(R))#{<<"kind">> => <<"rejected">>,<<"reason">> => <<"unavailable">>}),S
                            end;
                        _ -> wire(R,Id,(binding(R))#{<<"kind">> => <<"rejected">>,<<"reason">> => <<"transport">>}),S
                    end;
                _ -> wire(R0,Id,(binding(R0))#{<<"kind">> => <<"rejected">>,<<"reason">> => Reason}),S
            end
    end.
worker(Role,Context,Id,R) -> #{role => Role,owner => self(),context => Context,subscription => Id,
    attempt => maps:get(attempt,R),descriptor => maps:get(descriptor,R)}.
restore_one(_,_,#{suspended := true} = S) -> S;
restore_one(Id,Automatic,#{subscriptions := Items,offers := Offers,contracts := Contracts} = S) ->
    #{intent := I,session := Session,state := State,retry_at := Retry} = R = maps:get(Id,Items),
    Peer = maps:get(device,I),Key = maps:get(source_key,I),
    Ready = Session=:=undefined andalso State=/=opening andalso now_ms()>=Retry andalso
        (not Automatic orelse clock_ready(S)),
    case {Ready,maps:find({Peer,Key},Offers),maps:find({receive_audio,Peer,Key},Contracts),context(Peer)} of
        {true,{ok,#{incarnation := Inc,profiles := #{channel := D}}},{ok,Contract},{ok,#{buffee := Buffee} = Context}}
            when Buffee=:=map_get(buffee,I) ->
            case backend_missing(D) of
                true -> put_sub(Id,R#{state := waiting_for_backend,error => missing_backend_reason(D),retry_at := now_ms()+1000},S);
                false ->
            Attempt = fresh(),Next = (maps:remove(error,R))#{state := opening,context => Context,attempt => Attempt,source => Key,
                incarnation => Inc,descriptor => D,retry_at := now_ms()+10000},
            P = (binding(Next))#{<<"kind">> => <<"subscribe">>,<<"contract">> => maps:get(id,Contract),
                                 <<"revision">> => maps:get(revision,Contract)},
            case wire(Next,Id,P) of ok -> put_sub(Id,Next,S);_ -> S end
            end;
        _ ->
            case State=:=opening andalso now_ms()>=Retry of
                true -> put_sub(Id,close_receiver(Id,R),S);false -> S
            end
    end.
clock_ready(S) ->
    Module = ba_settings:app(audio_clock_adapter,ba_buffee_clock),
    try ba_subscription:clock_ready(Module:status(),maps:get(resume_after,S)) catch _:_ -> false end.
start_playback(Id,#{intent := #{playing := true},source_paused := false} = R) ->
    case enable_output(Id,R) of {ok,Next} -> Next;{error,E} -> R#{error => E,mix_ready => false} end;
start_playback(_,R) -> R.
enable_output(_,#{session := P,intent := I}=R) ->
    case native_output(P,{gain,maps:get(gain,I)}) of
        ok -> case native_output(P,{output,play}) of ok -> {ok,maps:remove(error,R#{mix_ready => true})};E -> E end;
        E -> E
    end.
catalog(Peer,#{catalogs := Cs} = S) ->
    case {maps:is_key(Peer,Cs),context(Peer)} of
        {false,{ok,#{session := Session}}} ->
            Id = fresh(),
            case send(Peer,Id,#{<<"kind">> => <<"catalog.read">>}) of
                ok -> {ok,S#{catalogs := Cs#{Peer => #{id => Id,session => Session,deadline => now_ms()+5000,offers => #{}}}}};
                Error -> {Error,S}
            end;
        %% A known source whose relationship lapsed: say hello; its start
        %% (audio_session_up) triggers the read.
        {false,_} -> ba_buffee_control:introduce(Peer),{{error,no_session},S};
        _ -> {{error,pending},S}
    end.
%% Dark Sessions: an ON AIR Device tells the Devices it can reach that it has
%% something to subscribe to ("subscribe to my audio"); each decides under its
%% own Playback consent ("open your speakers"). Nobody discovers sources.
announce_catalog(#{sources := Sources}=S) ->
    Readers = readers(),announce(Readers,S),
    %% Beyond direct neighbours, the announcement spreads by gossip.
    case map_size(Sources)>0 of
        true -> try ba_buffee_membership:announce(<<"on_air">>) catch exit:_ -> ok end;
        false -> ok
    end,
    S#{announced => Readers,announce_at => now_ms()+30000}.
%% New reachable Devices hear about live sources; all hear again every 30 s.
announce_new(#{sources := Sources}=S) when map_size(Sources)>0 ->
    case now_ms()>=maps:get(announce_at,S,0) of
        true -> announce_catalog(S);
        false ->
            Readers = readers(),New = Readers--maps:get(announced,S,[]),
            announce(New,S),S#{announced => lists:usort(maps:get(announced,S,[])++New)}
    end;
announce_new(S) -> S.
announce(Peers,_) -> [send(Peer,fresh(),#{<<"kind">> => <<"catalog.changed">>}) || Peer <- Peers],ok.
%% Devices this one can reach that may read catalogues.
readers() ->
    case membership() of
        {ok,#{policy := #{peers := Peers}}} ->
            [Peer || {Peer,Permissions} <- maps:to_list(Peers),lists:member(stream_read,Permissions),
                not ba_app_session:excluded(Peer)];
        _ -> []
    end.
%% Sources this Device knows of: current offers and saved subscriptions.
known_sources(#{offers := Offers,subscriptions := Subs}=S) ->
    Now = now_ms(),
    lists:usort([P || {P,_} <- maps:keys(Offers)]++[maps:get(device,I) || #{intent := I} <- maps:values(Subs)]++
        [P || {P,Until} <- maps:to_list(maps:get(wanted,S,#{})),Until>Now]).
refresh_all(S) -> lists:foldl(fun(Peer,Acc) -> {_,Next}=catalog(Peer,Acc),Next end,S,known_sources(S)).
membership() -> try ba_buffee_membership:current() catch exit:_ -> {error,unavailable} end.
context(Peer) -> try ba_buffee_control:audio_context(Peer) catch exit:_ -> {error,unavailable} end.
send(Peer,Id,P) -> ba_buffee_control:audio_message(Peer,Id,P).
wire(#{context := #{peer := Peer,session := Session,deadline := Deadline}},Id,P) ->
    Now = now_ms(),
    case context(Peer) of
        {ok,#{session := Session}} when Deadline>Now -> send(Peer,Id,P);
        _ -> {error,session_lost}
    end.
binding(R) -> #{<<"source">> => maps:get(source,R),<<"incarnation">> => maps:get(incarnation,R),<<"attempt">> => maps:get(attempt,R)}.
matches(#{peer := Peer,session := Session,buffee := Buffee},P,#{context := #{peer := Peer,session := Session,buffee := Buffee,deadline := Deadline}} = R) ->
    true = now_ms()<Deadline,true = maps:with([<<"source">>,<<"incarnation">>,<<"attempt">>],P)=:=binding(R),ok.
bound_transport(Context,Id,P,S) ->
    #{peer := Peer,session := Session} = Context,
    case maps:find(Id,maps:get(subscriptions,S)) of
        {ok,R} -> matches(Context,P,R),true = is_pid(maps:get(session,R)),{receiver,Id,R};
        error -> K = {Peer,Session,Id},R = maps:get(K,maps:get(providers,S)),matches(Context,P,R),{provider,K,R}
    end.
transport(Pid,S) ->
    Receivers = [{receiver,Id,R} || {Id,#{session := P}=R} <- maps:to_list(maps:get(subscriptions,S)),P=:=Pid],
    Providers = [{provider,K,R} || {K,#{session := P}=R} <- maps:to_list(maps:get(providers,S)),P=:=Pid],
    case Receivers++Providers of [Match] -> Match;_ -> none end.
put_sub(Id,R,S) -> S#{subscriptions := (maps:get(subscriptions,S))#{Id := R}}.
closed(_,R) ->
    case maps:find(monitor,R) of {ok,Ref} -> demonitor(Ref,[flush]);error -> ok end,
    (maps:without([monitor,context,attempt,incarnation,descriptor,source_paused,mix_ready],R))#{
        session := undefined,state := waiting_for_source,retry_at := now_ms()+1000}.
close_receiver(Id,R) ->
    case maps:get(session,R) of
        Pid when is_pid(Pid) -> _ = wire(R,Id,(binding(R))#{<<"kind">> => <<"close">>}),stop_worker(Pid);
        _ -> ok
    end,closed(Id,R).
close_provider(Key,R,S) ->
    demonitor(maps:get(monitor,R),[flush]),stop_worker(maps:get(session,R)),
    S#{providers := maps:remove(Key,maps:get(providers,S))}.
stop_worker(Pid) -> try gen_server:stop(Pid,normal,1000) catch exit:_ -> exit(Pid,kill) end.
unsubscribe(Id,S) ->
    case maps:find(Id,maps:get(subscriptions,S)) of
        {ok,R} -> _ = close_receiver(Id,R),persist(S#{subscriptions := maps:remove(Id,maps:get(subscriptions,S))});
        error -> S
    end.
scoped(Peer,Session,#{context := #{peer := Peer,session := Session}}) -> true;
scoped(_,_,_) -> false.
stop_matching(Predicate,S) ->
    Subs = maps:map(fun(Id,R) -> case Predicate(R) of true -> close_receiver(Id,R);false -> R end end,maps:get(subscriptions,S)),
    lists:foldl(fun({K,R},Acc) -> case Predicate(R) of true -> close_provider(K,R,Acc);false -> Acc end end,
        S#{subscriptions := Subs},maps:to_list(maps:get(providers,S))).
stop_contract({Direction,Peer,Key},S) ->
    case Direction of
        receive_audio ->
            Subs = maps:map(fun(Id,#{intent := I}=R) ->
                case maps:get(device,I)=:=Peer andalso maps:get(source_key,I)=:=Key of
                    true -> close_receiver(Id,R);false -> R
                end
            end,maps:get(subscriptions,S)),S#{subscriptions := Subs};
        publish -> lists:foldl(fun({K,#{context := #{peer := P},source := Source}=R},Acc) ->
            case P=:=Peer andalso Source=:=Key of
                true -> wire(R,maps:get(subscription,R),(binding(R))#{<<"kind">> => <<"close">>}),close_provider(K,R,Acc);
                false -> Acc
            end
        end,S,maps:to_list(maps:get(providers,S)))
    end.
disconnect_all(S) -> stop_matching(fun(_) -> true end,S).
persist(S) ->
    ok = ba_subscription:save(maps:map(fun(_,R) -> maps:get(intent,R) end,maps:get(subscriptions,S))),S.
reject(S) -> ba_diagnostics:count(invalid_control_or_attempt,S#{rejected := maps:get(rejected,S)+1}).
fresh() -> binary:encode_hex(crypto:strong_rand_bytes(16)).
now_ms() -> erlang:monotonic_time(millisecond).
terminate(_,S) ->
    [stop_worker(P) || #{session := P} <- maps:values(maps:get(subscriptions,S)),is_pid(P)],
    [stop_worker(maps:get(session,R)) || R <- maps:values(maps:get(providers,S))],ok.

format_status(Status) -> maps:map(fun(state,S) -> maps:with([suspended,rejected],S);(log,_) -> [];(_,_) -> redacted end,Status).

resync_clock(Reason) ->
    Module = ba_settings:app(audio_clock_adapter,ba_buffee_clock),
    try case erlang:function_exported(Module,resync,1) of
        true -> Module:resync(Reason);false -> Module:resync()
    end catch _:_ -> unavailable end.

renew_media(Id,Peer,Session,Until,#{context := #{peer := Peer,session := Session,deadline := Old}=C,session := P}=R)
        when Until>Old ->
    gen_server:cast(P,{renew,self(),Until}),
    Updated = R#{context := C#{deadline := Until}},
    _ = Id,Updated;
renew_media(_,_,_,_,R) -> R.

transport_status(#{session := P}) when is_pid(P) ->
    try gen_server:call(P,status,100) catch exit:_ -> #{error => unavailable} end;
transport_status(_) -> #{}.

publication_allowed(Peer,Key) ->
    case ba_settings:app(runtime_profile,legacy_apps) of
        buffee_control -> buffee_publication_allowed(Peer,Key);
        _ -> true
    end.
buffee_publication_allowed(Peer,Key) ->
    case membership() of
        {ok,#{device_privileges := Privileges}} ->
            case maps:find(Peer,Privileges) of
                {ok,Held} -> ba_session_privileges:may_publish(Held,Key);
                error -> false
            end;
        _ -> false
    end.

%% Native output is the only output: this Device needs its native stream host.
backend_missing(_) -> not ba_native_media_session:available().
disable_output(_,#{session := P}) when is_pid(P) -> native_output(P,{output,pause});
disable_output(_,_) -> ok.
output_gain(_,G,#{session := P}) -> native_output(P,{gain,G}).

native_output(P,Command) ->
    try gen_server:call(P,Command,1500) catch exit:_ -> {error,native_endpoint_unavailable} end.

missing_backend_reason(_) -> native_backend_unavailable.
