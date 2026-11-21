%% Owns independent durable subscriptions and local publication permissions.
%% Media is the native engine only: this process receives publications and routes subscription
%% and stream-setup control; audio never passes through it.
-module(ba_audio_receiver).
-behaviour(gen_server).
-export([start_link/0,snapshot/0,subscribe/3,stop/0,stop/1,
         playback/2,set_contract/5,clear_contract/3,register_source/1,
         suspend/0,resume/0,network_changed/0]).
-export([init/1,handle_call/3,handle_cast/2,handle_info/2,terminate/2,format_status/1]).
start_link() -> gen_server:start_link(ba_session_scope:registration(?MODULE),?MODULE,[],[]).
snapshot() -> call(snapshot).
subscribe(Peer,Source,Profile) -> call({subscribe,Peer,Source,Profile}).
stop() -> call(stop).
stop(Id) -> call({stop,Id}).
playback(Id,Action) -> call({playback,Id,Action}).
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
    Control = ba_session_scope:whereis(ba_session_control),true = is_pid(Control),monitor(process,Control),
    {ok,#{sources => #{},offers => #{},subscriptions => maps:map(fun(_,I) -> waiting(I) end,Items),
          providers => #{},publication_versions => #{},contracts => #{},control => Control,
          suspended => false,resume_after => undefined,rejected => 0,link_due => now_ms()+10000}}.
waiting(I) -> #{intent => I,state => waiting_for_source,media => undefined,retry_at => now_ms()}.
handle_call(snapshot,_,S) ->
    View = maps:map(fun(_,R) ->
        I = maps:get(intent,R),(maps:merge(I,maps:with([state,source_paused,error,mix_ready],R)))#{transport => transport_status(R)}
    end,maps:get(subscriptions,S)),
    Rows = [(maps:remove(expires_at,O))#{device => Peer,source_key => Key} || {{Peer,Key},O} <- maps:to_list(maps:get(offers,S))],
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
        {reply,ok,announce_publication(Key,map_size(Sources)=:=0,S#{sources := Sources#{Key => Entry}})}
    catch throw:on_air_required -> {reply,{error,on_air_required},S};
          _:_ -> {reply,{error,invalid_or_duplicate_publication},S} end;
handle_call({contract,Direction,Peer,Key,Id,Revision},_,#{contracts := Contracts} = S) ->
    try
        true = Direction=:=publish orelse Direction=:=receive_audio,
        true = ba_hex:valid(Peer,64),true = ba_hex:valid(Id,32),
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
handle_call({subscribe,Peer,Key,channel},_,#{subscriptions := Items,offers := Offers} = S) when map_size(Items)<16 ->
    Existing = lists:any(fun(R) -> I = maps:get(intent,R),maps:get(device,I)=:=Peer andalso maps:get(source_key,I)=:=Key end,maps:values(Items)),
    case {Existing,maps:find({Peer,Key},Offers),context(Peer)} of
        {false,{ok,O},{ok,#{session := Session}}} ->
            I = ba_subscription:new(Session,Peer,O,channel),Id = maps:get(id,I),
            Next = persist(S#{subscriptions := Items#{Id => waiting(I)}}),
            {reply,{ok,Id},restore_one(Id,false,Next)};
        {true,_,_} -> {reply,{error,already_subscribed},S};
        {false,{ok,_},_} -> {reply,{error,source_or_link_unavailable},introduce(Peer,S)};
        _ -> {reply,{error,source_or_link_unavailable},S}
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
handle_call(suspend,_,S) -> {reply,ok,disconnect_all(S#{suspended := true})};
handle_call(resume,_,S) ->
    resync_clock(resume),
    {reply,ok,disconnect_all(S#{suspended := false,resume_after := erlang:monotonic_time(nanosecond)})};
handle_call(_,_,S) -> {reply,{error,unsupported_request},S}.
%% A path notification is a discovery hint, not proof that authenticated media
%% or the reference clock failed. Their own monitors, leases and sample freshness
%% fence real failures. Restarting acquisition here creates repeated audio bursts.
handle_cast(network_changed,S) ->
    %% Media workers check their addresses now instead of at their next poll;
    %% they reconnect only if the addresses really changed.
    [P ! network_hint || P <- ba_audio_sup:media()],
    {noreply,S#{link_due => now_ms()}};
handle_cast(_,S) -> {noreply,S}.
handle_info({publication,Peer,Body},S) -> {noreply,receive_publication(Peer,Body,S)};
handle_info(tick,S) ->
    erlang:send_after(250,self(),tick),
    Next = maintain_links(renew_publications(expire_publications(S))),
    Final = lists:foldl(fun(Id,Acc) -> restore_one(Id,true,Acc) end,Next,maps:keys(maps:get(subscriptions,Next))),
    Recovered=case maps:get(suspended,Final) of
        true -> Final;
        false -> Final#{subscriptions := maps:map(fun(Id,R) ->
            case maps:get(state,R)=:=active andalso not maps:get(mix_ready,R,false) of
                true -> start_playback(Id,R);false -> R
            end end,maps:get(subscriptions,Final))}
    end,
    Subs = maps:get(subscriptions,Recovered),
    Playing = lists:sort([Id || {Id,#{state := active,mix_ready := true,intent := #{playing := true}}} <- maps:to_list(Subs)]),
    Failed = lists:any(fun(#{intent := I}=R) -> maps:get(playing,I,false) andalso maps:is_key(error,R) end,maps:values(Subs)),
    ba_response_time:playback(maps:keys(Subs),Playing,Failed),
    {noreply,Recovered};
handle_info({session_audio,Context,Id,P},S) ->
    try
        #{peer := Peer,link := Link,session := Session,deadline := Deadline} = Context,
        true = now_ms()<Deadline,
        {ok,#{link := Link,session := Session}} = context(Peer),
        incoming(Context,Id,P,S)
    of Next -> {noreply,Next}
    catch _:_ ->
        %% Signalling for an attempt that already ended (e.g. after a setup
        %% timeout) is expected noise; keep it apart from invalid control.
        %% Diagnostics must never take the receiver down.
        try explain(Context,Id,P,S) catch _:_ -> ok end,
        case P of
            #{<<"kind">> := <<"signal.",_/binary>>} ->
                {noreply,ba_diagnostics:count(stale_media_signal,S#{rejected := maps:get(rejected,S)+1})};
            _ -> {noreply,reject(S)}
        end
    end;
handle_info({audio_link_renewed,#{peer := Peer,link := Link,deadline := Until}},S) ->
    %% The owner emits this while the peer's authenticated packets keep
    %% arriving; a later packet may already have moved the deadline further.
    case context(Peer) of
        {ok,#{link := Link,deadline := Current}} when Current>=Until ->
            Subs = maps:map(fun(Id,R) -> renew_media(Id,Peer,Link,Until,R) end,maps:get(subscriptions,S)),
            Providers = maps:map(fun(_,R) -> renew_media(undefined,Peer,Link,Until,R) end,maps:get(providers,S)),
            {noreply,S#{subscriptions := Subs,providers := Providers}};
        _ -> {noreply,reject(S)}
    end;
handle_info({audio_link_down,Peer,Link},S) ->
    {noreply,stop_matching(fun(R) -> scoped(Peer,Link,R) end,S)};
handle_info({audio_signal,Pid,P},S) ->
    case transport(Pid,S) of
        {Side,Key,R} ->
            Id = case Side of provider -> maps:get(subscription,R);receiver -> Key end,
            case wire(R,Id,maps:merge(binding(R),P)) of
                ok -> {noreply,S};
                Error ->
                    logger:warning("Native ~p ~ts send failed: ~p",[Side,maps:get(<<"kind">>,P),Error]),
                    Next = case Side of receiver -> put_sub(Key,close_receiver(Key,R),S);provider -> close_provider(Key,R,signal_send_failed,S) end,
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
                    true -> _ = wire(R,maps:get(subscription,R),(binding(R))#{<<"kind">> => <<"close">>}),close_provider(K,R,publication_rebound,Acc);
                    false -> Acc
                end
            end,S,maps:to_list(maps:get(providers,S))),
            {noreply,announce_publication(Key,Next#{sources := Sources#{Key := E#{offer := Offer}}})};
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
            {noreply,case maps:get(paused,O)=:=B of true -> Next;false -> announce_publication(Key,Next) end};
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
            logger:notice("Native provider exited: ~p",[ba_diagnostics:reason(Reason)]),
            Removed = S#{providers := maps:remove(Key,maps:get(providers,S))},
            case Reason of normal -> Removed;_ -> ba_diagnostics:count(Reason,Removed) end;
        none -> S
    end,
    OldSources = maps:get(sources,Next),
    Sources = maps:filter(fun(_,#{monitor := M}) -> M=/=Ref end,OldSources),
    Updated=Next#{sources := Sources},
    {noreply,lists:foldl(fun announce_publication/2,Updated,maps:keys(OldSources)--maps:keys(Sources))};
handle_info(_,S) -> {noreply,S}.

incoming(Context,Id,#{<<"kind">> := <<"subscribe">>} = P,S) -> admit(Context,Id,P,S);
incoming(Context,Id,#{<<"kind">> := <<"accepted">>} = P,S) ->
    R = maps:get(Id,maps:get(subscriptions,S)),matches(Context,P,R),opening = maps:get(state,R),
    undefined = maps:get(media,R),
    case ba_audio_sup:start_media(worker(receiver,Context,Id,R)) of
        {ok,Pid} ->
            Ref = monitor(process,Pid),
            put_sub(Id,R#{media := Pid,monitor => Ref,source_paused => maps:get(<<"paused">>,P)},S);
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
                provider -> close_provider(Key,R,remote_close,S)
            end;
        <<"state">> when Side=:=receiver ->
            B = maps:get(<<"paused">>,P),
            _ = disable_output(Key,R),
            put_sub(Key,start_playback(Key,R#{source_paused => B,mix_ready => false}),S);
        _ when Kind=:= <<"signal.endpoint">>;Kind=:= <<"signal.stream">> ->
            gen_server:cast(maps:get(media,R),{signal,P}),S
    end.

admit(#{peer := Peer,link := Link} = Context,Id,P,#{sources := Sources,providers := Providers} = S) ->
    Key = maps:get(<<"source">>,P),Inc = maps:get(<<"incarnation">>,P),Attempt = maps:get(<<"attempt">>,P),
    ProviderKey = {Peer,Link,Id},
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
                    case ba_audio_sup:start_media((worker(provider,Context,Id,R))#{source_pid => Source}) of
                        {ok,Pid} ->
                            Attached = try gen_server:call(Source,{attach,Pid},100) catch exit:_ -> unavailable end,
                            case Attached of
                                ok ->
                                    Ref = monitor(process,Pid),
                                    wire(R,Id,(binding(R))#{<<"kind">> => <<"accepted">>,<<"paused">> => Paused}),
                                    S#{providers := Providers#{ProviderKey => R#{media => Pid,monitor => Ref}}};
                                _ ->
                                    logger:warning("Native provider attach failed: ~p",[Attached]),
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
    #{intent := I,media := Media,state := State,retry_at := Retry} = R = maps:get(Id,Items),
    Peer = maps:get(device,I),Key = maps:get(source_key,I),
    Ready = Media=:=undefined andalso State=/=opening andalso now_ms()>=Retry andalso
        (not Automatic orelse clock_ready(S)),
    case {Ready,maps:find({Peer,Key},Offers),maps:find({receive_audio,Peer,Key},Contracts),context(Peer)} of
        {true,{ok,#{incarnation := Inc,profiles := #{channel := D}}},{ok,Contract},{ok,#{session := Session} = Context}}
            when Session=:=map_get(session,I) ->
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
    Module = ba_settings:app(audio_clock_adapter,ba_session_clock),
    try ba_subscription:clock_ready(Module:status(),maps:get(resume_after,S)) catch _:_ -> false end.
start_playback(Id,#{intent := #{playing := true},source_paused := false} = R) ->
    case enable_output(Id,R) of {ok,Next} -> Next;{error,E} -> R#{error => E,mix_ready => false} end;
start_playback(_,R) -> R.
enable_output(_,#{media := P}=R) ->
    case native_output(P,{output,play}) of
        ok -> {ok,maps:remove(error,R#{mix_ready => true})};
        E -> E
    end.
%% A signed source update replaces earlier revisions from the same Device.
%% Retain withdrawal revisions after removing their offers so delayed gossip
%% cannot make the source live again.
receive_publication(Peer,#{<<"source">> := Key,<<"revision">> := Rev,<<"offer">> := Wire},S) ->
    Ref={Peer,Key},Versions=maps:get(publication_versions,S,#{}),
    case Rev>element(1,maps:get(Ref,Versions,{0,0})) of
        false -> S;
        true ->
            Now=now_ms(),Next=S#{publication_versions => Versions#{Ref => {Rev,Now+60000}}},
            case Wire=/=null andalso publication_allowed(Peer,Key) andalso not ba_app_session:excluded(Peer) of
                false -> remove_offer(Ref,Next);
                true ->
                    Inc=maps:get(<<"incarnation">>,Wire),Offers=maps:get(offers,Next),
                    Updated=case maps:get(Ref,Offers,undefined) of
                        #{incarnation := Old} when Old=/=Inc -> remove_offer(Ref,Next);
                        _ -> Next
                    end,
                    Offer=#{name => maps:get(<<"name">>,Wire),source_key => Key,incarnation => Inc,
                        paused => maps:get(<<"paused">>,Wire),profiles => #{channel => ba_audio_stream_protocol:descriptor(Wire)},
                        expires_at => Now+30000},
                    Updated#{offers := (maps:get(offers,Updated))#{Ref => Offer}}
            end
    end.

remove_offer({Peer,Key}=Ref,#{offers := Offers}=S) ->
    case maps:is_key(Ref,Offers) of
        true -> stop_contract({receive_audio,Peer,Key},S#{offers := maps:remove(Ref,Offers)});
        false -> S
    end.

expire_publications(#{offers := Offers}=S) ->
    Now=now_ms(),Versions=maps:filter(fun(_,{_,Until}) -> Now<Until end,maps:get(publication_versions,S,#{})),
    lists:foldl(fun remove_offer/2,S#{publication_versions => Versions},
        [Ref || {Ref,#{expires_at := Until}} <- maps:to_list(Offers),Now>=Until]).

announce_publication(Key,S) -> announce_publication(Key,false,S).

announce_publication(Key,Refresh,#{sources := Sources}=S) ->
    Wire=case maps:find(Key,Sources) of
        {ok,#{offer := Offer}} -> ba_audio_stream_protocol:offer(Key,maps:get(incarnation,Offer),Offer);
        error -> null
    end,
    Revision=max(erlang:system_time(microsecond),maps:get(publication_revision,S,0)+1),
    ba_session_membership:announce(<<"publication">>,#{<<"source">> => Key,<<"revision">> => Revision,
        <<"offer">> => Wire,<<"refresh_levels">> => Refresh}),
    S#{publication_revision => Revision}.

renew_publications(S) ->
    Now=now_ms(),
    case Now>=maps:get(publish_due,S,Now) of
        true -> lists:foldl(fun announce_publication/2,S#{publish_due => Now+10000},maps:keys(maps:get(sources,S,#{})));
        false -> S
    end.

%% Keep relationships only for subscriptions. Introductions never read source
%% data: the signed announcement already contains the descriptor.
maintain_links(#{subscriptions := Subs,offers := Offers}=S) ->
    Now=now_ms(),Next=S#{introductions => maps:filter(fun(_,Until) -> Now<Until end,maps:get(introductions,S,#{}))},
    case not maps:get(suspended,S) andalso Now>=maps:get(link_due,S,Now) of
        true ->
            Peers=lists:usort([P || #{intent := #{device := P,source_key := Key}} <- maps:values(Subs),
                maps:is_key({P,Key},Offers)]),
            lists:foldl(fun introduce/2,Next#{link_due => Now+10000},Peers);
        false -> Next
    end.

introduce(Peer,S) ->
    Now=now_ms(),Recent=maps:get(introductions,S,#{}),
    case Now>=maps:get(Peer,Recent,Now) of
        true -> ba_session_control:introduce(Peer),S#{introductions => Recent#{Peer => Now+2000}};
        false -> S
    end.

membership() -> try ba_session_membership:current() catch exit:_ -> {error,unavailable} end.
context(Peer) -> try ba_session_control:audio_context(Peer) catch exit:_ -> {error,unavailable} end.
send(Peer,Id,P) -> ba_session_control:audio_message(Peer,Id,P).
wire(#{context := #{peer := Peer,link := Link,deadline := Deadline}},Id,P) ->
    Now = now_ms(),
    case context(Peer) of
        {ok,#{link := Link}} when Deadline>Now -> send(Peer,Id,P);
        _ -> {error,link_lost}
    end.
binding(R) -> #{<<"source">> => maps:get(source,R),<<"incarnation">> => maps:get(incarnation,R),<<"attempt">> => maps:get(attempt,R)}.
matches(#{peer := Peer,link := Link,session := Session},P,#{context := #{peer := Peer,link := Link,session := Session,deadline := Deadline}} = R) ->
    true = now_ms()<Deadline,true = maps:with([<<"source">>,<<"incarnation">>,<<"attempt">>],P)=:=binding(R),ok.
bound_transport(Context,Id,P,S) ->
    #{peer := Peer,link := Link} = Context,
    case maps:find(Id,maps:get(subscriptions,S)) of
        {ok,R} -> matches(Context,P,R),true = is_pid(maps:get(media,R)),{receiver,Id,R};
        error -> K = {Peer,Link,Id},R = maps:get(K,maps:get(providers,S)),matches(Context,P,R),{provider,K,R}
    end.
transport(Pid,S) ->
    Receivers = [{receiver,Id,R} || {Id,#{media := P}=R} <- maps:to_list(maps:get(subscriptions,S)),P=:=Pid],
    Providers = [{provider,K,R} || {K,#{media := P}=R} <- maps:to_list(maps:get(providers,S)),P=:=Pid],
    case Receivers++Providers of [Match] -> Match;_ -> none end.
put_sub(Id,R,S) -> S#{subscriptions := (maps:get(subscriptions,S))#{Id := R}}.
closed(_,R) ->
    case maps:find(monitor,R) of {ok,Ref} -> demonitor(Ref,[flush]);error -> ok end,
    (maps:without([monitor,context,attempt,incarnation,descriptor,source_paused,mix_ready],R))#{
        media := undefined,state := waiting_for_source,retry_at := now_ms()+1000}.
close_receiver(Id,R) ->
    case maps:get(media,R) of
        Pid when is_pid(Pid) -> _ = wire(R,Id,(binding(R))#{<<"kind">> => <<"close">>}),stop_worker(Pid);
        _ -> ok
    end,closed(Id,R).
close_provider(Key,R,Reason,S) ->
    logger:notice("Native provider closed: ~p",[Reason]),
    demonitor(maps:get(monitor,R),[flush]),stop_worker(maps:get(media,R)),
    S#{providers := maps:remove(Key,maps:get(providers,S))}.
stop_worker(Pid) -> try gen_server:stop(Pid,normal,1000) catch exit:_ -> exit(Pid,kill) end.
unsubscribe(Id,S) ->
    case maps:find(Id,maps:get(subscriptions,S)) of
        {ok,R} -> _ = close_receiver(Id,R),persist(S#{subscriptions := maps:remove(Id,maps:get(subscriptions,S))});
        error -> S
    end.
scoped(Peer,Link,#{context := #{peer := Peer,link := Link}}) -> true;
scoped(_,_,_) -> false.
stop_matching(Predicate,S) ->
    Subs = maps:map(fun(Id,R) -> case Predicate(R) of true -> close_receiver(Id,R);false -> R end end,maps:get(subscriptions,S)),
    lists:foldl(fun({K,R},Acc) -> case Predicate(R) of true -> close_provider(K,R,link_closed,Acc);false -> Acc end end,
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
                true -> wire(R,maps:get(subscription,R),(binding(R))#{<<"kind">> => <<"close">>}),close_provider(K,R,contract_changed,Acc);
                false -> Acc
            end
        end,S,maps:to_list(maps:get(providers,S)))
    end.
disconnect_all(S) -> stop_matching(fun(_) -> true end,S).
persist(S) ->
    ok = ba_subscription:save(maps:map(fun(_,R) -> maps:get(intent,R) end,maps:get(subscriptions,S))),S.
reject(S) -> ba_diagnostics:count(invalid_control_or_attempt,S#{rejected := maps:get(rejected,S)+1}).
%% Why a stream message was discarded, logged at most once a second, so a
%% failing setup can be read from runtime.log instead of guessed from counters.
explain(Context,Id,P,S) ->
    Now = now_ms(),
    case Now-(case get(last_explained) of undefined -> Now-1000;T -> T end) >= 1000 of
        false -> ok;
        true ->
            put(last_explained,Now),
            Kind = maps:get(<<"kind">>,P,<<"?">>),
            Peer = maps:get(peer,Context,<<"?">>),Link = maps:get(link,Context,undefined),
            Reason = try
                case context(Peer) of
                    {ok,#{link := Link}} -> ok;
                    {ok,_} -> throw(relationship_changed);
                    _ -> throw(no_relationship)
                end,
                case now_ms() < maps:get(deadline,Context,0) of true -> ok;false -> throw(context_expired) end,
                {Side,R} = case maps:find(Id,maps:get(subscriptions,S)) of
                    {ok,Sub} -> {receiver,Sub};
                    error -> case maps:find({Peer,Link,Id},maps:get(providers,S)) of
                        {ok,Prov} -> {provider,Prov};
                        error -> throw({unknown_attempt,map_size(maps:get(providers,S)),map_size(maps:get(subscriptions,S))})
                    end
                end,
                Bound = maps:with([<<"source">>,<<"incarnation">>,<<"attempt">>],P),
                case (try binding(R) catch _:_ -> none end) of Bound -> ok;_ -> throw({old_attempt,Side}) end,
                case maps:find(context,R) of
                    {ok,#{link := Link}} -> ok;
                    {ok,_} -> throw({attempt_from_other_relationship,Side});
                    error -> throw({no_context,Side})
                end,
                case Side=:=provider orelse is_pid(maps:get(media,R,undefined)) of true -> ok;false -> throw({not_open,maps:get(state,R,undefined)}) end,
                handler_failed
            catch throw:Why -> Why;_:Error -> {check_failed,Error} end,
            logger:warning("Discarded ~ts from ~ts (~ts): ~p",[Kind,binary:part(Peer,0,min(8,byte_size(Peer))),Id,Reason])
    end.
fresh() -> binary:encode_hex(crypto:strong_rand_bytes(16)).
now_ms() -> erlang:monotonic_time(millisecond).
terminate(_,S) ->
    [stop_worker(P) || #{media := P} <- maps:values(maps:get(subscriptions,S)),is_pid(P)],
    [stop_worker(maps:get(media,R)) || R <- maps:values(maps:get(providers,S))],ok.

format_status(Status) -> maps:map(fun(state,S) -> maps:with([suspended,rejected],S);(log,_) -> [];(_,_) -> redacted end,Status).

resync_clock(Reason) ->
    Module = ba_settings:app(audio_clock_adapter,ba_session_clock),
    try case erlang:function_exported(Module,resync,1) of
        true -> Module:resync(Reason);false -> Module:resync()
    end catch _:_ -> unavailable end.

renew_media(Id,Peer,Link,Until,#{context := #{peer := Peer,link := Link,deadline := Old}=C,media := P}=R)
        when Until>Old ->
    gen_server:cast(P,{renew,self(),Until}),
    Updated = R#{context := C#{deadline := Until}},
    _ = Id,Updated;
renew_media(_,_,_,_,R) -> R.

transport_status(#{media := P}) when is_pid(P) ->
    try gen_server:call(P,status,100) catch exit:_ -> #{error => unavailable} end;
transport_status(_) -> #{}.

publication_allowed(Peer,Key) ->
    case membership() of
        {ok,#{device_privileges := Privileges}} ->
            ba_session_privileges:may_publish(maps:get(Peer,Privileges,[]),Key);
        _ -> false
    end.

%% The native engine is the only output: this Device needs its executable.
backend_missing(_) -> not ba_audio_engine:available().
disable_output(_,#{media := P}) when is_pid(P) -> native_output(P,{output,pause});
disable_output(_,_) -> ok.

native_output(P,Command) ->
    try gen_server:call(P,Command,1500) catch exit:_ -> {error,native_endpoint_unavailable} end.

missing_backend_reason(_) -> native_backend_unavailable.
