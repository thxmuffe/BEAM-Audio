%% Owns independent durable subscriptions and local publication permissions.
-module(ba_audio_receiver).
-behaviour(gen_server).
-export([start_link/0,snapshot/0,refresh/0,refresh/1,subscribe/2,subscribe/3,stop/0,stop/1,
         playback/1,playback/2,gain/2,set_contract/5,clear_contract/3,register_source/1,
         suspend/0,resume/0,network_changed/0,minimum_playout_delay/1,control_output/1]).
-export([init/1,handle_call/3,handle_cast/2,handle_info/2,terminate/2,format_status/1]).
start_link() -> gen_server:start_link({local,?MODULE},?MODULE,[],[]).
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
network_changed() -> gen_server:cast(?MODULE,network_changed).
minimum_playout_delay(_) -> {error,unsupported_mixer_output_control}.
control_output(_) -> {error,unsupported_mixer_output_control}.
call(Request) ->
    case ba_audio_sup:ensure_started() of ok -> gen_server:call(?MODULE,Request,10000);Error -> Error end.
init([]) ->
    Items = ba_subscription:load(),
    erlang:send_after(250,self(),tick),
    Control = whereis(ba_swarm_control),true = is_pid(Control),monitor(process,Control),
    {ok,#{sources => #{},offers => #{},subscriptions => maps:map(fun(_,I) -> waiting(I) end,Items),
          providers => #{},catalogs => #{},contracts => #{},control => Control,
          suspended => false,resume_after => undefined,rejected => 0,poll_at => now_ms()}}.
waiting(I) -> #{intent => I,state => waiting_for_source,session => undefined,retry_at => now_ms(),packets => 0}.
handle_call(snapshot,_,S) ->
    View = maps:map(fun(_,R) ->
        I = maps:get(intent,R),maps:merge(I,maps:with([state,packets,source_paused,error],R))
    end,maps:get(subscriptions,S)),
    Rows = [O#{device => Peer,source_key => Key} || {{Peer,Key},O} <- maps:to_list(maps:get(offers,S))],
    {reply,#{subscriptions => View,offers => Rows,publications => map_size(maps:get(sources,S)),
             providers => map_size(maps:get(providers,S)),mixer => ba_audio_mixer:status(),
             rejected => maps:get(rejected,S)},S};
handle_call({register,Pid},_,#{sources := Sources} = S) when is_pid(Pid),node(Pid)=:=node(),map_size(Sources)<16 ->
    try
        Offer = gen_server:call(Pid,describe,100),Key = maps:get(source_key,Offer),
        false = maps:is_key(Key,Sources),
        _ = ba_audio_stream_protocol:offer(Key,maps:get(incarnation,Offer),Offer),
        Ref = monitor(process,Pid),Entry = #{pid => Pid,monitor => Ref,offer => Offer},
        {reply,ok,S#{sources := Sources#{Key => Entry}}}
    catch _:_ -> {reply,{error,invalid_or_duplicate_publication},S} end;
handle_call({contract,Direction,Peer,Key,Id,Revision},_,#{contracts := Contracts} = S) ->
    try
        true = Direction=:=publish orelse Direction=:=receive_audio,
        true = ba_swarm_job:hex(Peer,64),true = ba_swarm_job:hex(Id,32),
        true = is_binary(Key) andalso byte_size(Key)>0 andalso byte_size(Key)=<128,
        true = is_integer(Revision) andalso Revision>0 andalso Revision=<9007199254740991,
        ContractKey = {Direction,Peer,Key},
        true = maps:is_key(ContractKey,Contracts) orelse map_size(Contracts)<32,
        Next = stop_contract(ContractKey,S),
        {reply,ok,Next#{contracts := Contracts#{ContractKey => #{id => Id,revision => Revision}}}}
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
        {false,{ok,O},{ok,#{swarm := Swarm}}} ->
            I = ba_subscription:new(Swarm,Peer,O,channel),Id = maps:get(id,I),
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
                {false,_,_} -> ba_audio_mixer:remove(Id),{ok,R#{mix_ready => false}};
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
            case maps:get(mix_ready,R,false) of true -> ba_audio_mixer:gain(Id,G);false -> ok end,
            {reply,ok,persist(S#{subscriptions := Items#{Id := R#{intent := I#{gain := G}}}})};
        error -> {reply,{error,unknown_subscription},S}
    end;
handle_call(suspend,_,S) -> {reply,ok,disconnect_all(S#{suspended := true})};
handle_call(resume,_,S) ->
    resync_clock(),
    {reply,ok,disconnect_all(S#{suspended := false,resume_after := erlang:monotonic_time(nanosecond)})};
handle_call(_,_,S) -> {reply,{error,unsupported_request},S}.
handle_cast(network_changed,S) -> resync_clock(),{noreply,disconnect_all(S#{resume_after := erlang:monotonic_time(nanosecond)})};
handle_cast(_,S) -> {noreply,S}.
handle_info(tick,S) ->
    erlang:send_after(250,self(),tick),
    Catalogs = maps:filter(fun(_,C) -> maps:get(deadline,C)>now_ms() end,maps:get(catalogs,S)),
    Next = case now_ms()>=maps:get(poll_at,S) of
        true -> refresh_all(S#{catalogs := Catalogs,poll_at := now_ms()+5000});
        false -> S#{catalogs := Catalogs}
    end,
    Final = lists:foldl(fun(Id,Acc) -> restore_one(Id,true,Acc) end,Next,maps:keys(maps:get(subscriptions,Next))),
    {noreply,Final};
handle_info({swarm_audio,Context,Id,P},S) ->
    try
        #{peer := Peer,session := Session,swarm := Swarm,deadline := Deadline} = Context,
        true = now_ms()<Deadline,
        {ok,#{session := Session,swarm := Swarm}} = context(Peer),
        incoming(Context,Id,P,S)
    of Next -> {noreply,Next}
    catch _:_ -> {noreply,reject(S)} end;
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
handle_info({audio_pcm,Pid,H,PCM},S) ->
    case transport(Pid,S) of
        {receiver,Id,#{intent := I,descriptor := D,context := #{deadline := Deadline}} = R} ->
            case maps:get(playing,I) andalso maps:get(mix_ready,R,false) andalso not maps:get(source_paused,R,false) andalso now_ms()<Deadline of
                true -> ba_audio_mixer:push(Id,ba_audio_opus:descriptor(D),H,PCM);
                false -> ok
            end,
            {noreply,put_sub(Id,R#{packets := maps:get(packets,R)+1},S)};
        _ -> {noreply,reject(S)}
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
            {noreply,Next#{sources := Sources#{Key := E#{offer := Offer}}}};
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
            {noreply,S#{sources := Sources#{Key := E#{offer := O#{paused := B}}},providers := Providers}};
        _ -> {noreply,reject(S)}
    end;
handle_info({'DOWN',_,process,Pid,_},#{control := Pid} = S) -> {stop,normal,S};
handle_info({'DOWN',Ref,process,Pid,_},S) ->
    Next = case transport(Pid,S) of
        {receiver,Id,R} -> put_sub(Id,closed(Id,R),S);
        {provider,Key,R} -> _ = wire(R,maps:get(subscription,R),(binding(R))#{<<"kind">> => <<"close">>}),
            S#{providers := maps:remove(Key,maps:get(providers,S))};
        none -> S
    end,
    Sources = maps:filter(fun(_,#{monitor := M}) -> M=/=Ref end,maps:get(sources,Next)),
    {noreply,Next#{sources := Sources}};
handle_info(_,S) -> {noreply,S}.

incoming(#{peer := Peer} = Context,Id,#{<<"kind">> := <<"catalog.read">>},S) ->
    maps:foreach(fun(Key,#{offer := Offer}) ->
        send(Peer,Id,ba_audio_stream_protocol:offer(Key,maps:get(incarnation,Offer),Offer))
    end,maps:get(sources,S)),send(Peer,Id,#{<<"kind">> => <<"catalog.end">>}),_ = Context,S;
incoming(#{peer := Peer,session := Session},Id,#{<<"kind">> := <<"catalog.offer">>} = P,#{catalogs := Cs} = S) ->
    #{id := Id,session := Session,deadline := Deadline,offers := Offers} = C = maps:get(Peer,Cs),
    true = now_ms()<Deadline,true = map_size(Offers)<16,
    Key = maps:get(<<"source">>,P),false = maps:is_key(Key,Offers),
    D = ba_audio_stream_protocol:descriptor(P),
    O = #{name => maps:get(<<"name">>,P),source_key => Key,incarnation => maps:get(<<"incarnation">>,P),
          paused => maps:get(<<"paused">>,P),profiles => #{channel => D}},
    S#{catalogs := Cs#{Peer := C#{offers := Offers#{Key => O}}}};
incoming(#{peer := Peer,session := Session},Id,#{<<"kind">> := <<"catalog.end">>},#{catalogs := Cs,offers := Old} = S) ->
    #{id := Id,session := Session,deadline := Deadline,offers := Offers} = maps:get(Peer,Cs),true = now_ms()<Deadline,
    Kept = maps:filter(fun({P,_},_) -> P=/=Peer end,Old),
    Added = maps:from_list([{{Peer,K},O} || {K,O} <- maps:to_list(Offers)]),
    S#{catalogs := maps:remove(Peer,Cs),offers := maps:merge(Kept,Added)};
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
            _ = ba_audio_mixer:remove(Key),
            put_sub(Key,start_playback(Key,R#{source_paused => B,mix_ready => false}),S);
        _ when Kind=:= <<"signal.offer">>;Kind=:= <<"signal.answer">>;Kind=:= <<"signal.candidate">> ->
            ba_media_session:signal(maps:get(session,R),P),S
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
        {true,{ok,#{incarnation := Inc,profiles := #{channel := D}}},{ok,Contract},{ok,#{swarm := Swarm} = Context}}
            when Swarm=:=map_get(swarm,I) ->
            case maps:get(encoding,D,pcm)=:=opus andalso not ba_audio_opus:available() of
                true -> put_sub(Id,R#{state := waiting_for_backend,error => opus_decoder_unavailable,retry_at := now_ms()+1000},S);
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
    Module = application:get_env(ba_core,audio_clock_adapter,ba_swarm_clock),
    try ba_subscription:clock_ready(Module:status(),maps:get(resume_after,S)) catch _:_ -> false end.
start_playback(Id,#{intent := #{playing := true},source_paused := false} = R) ->
    case enable_output(Id,R) of {ok,Next} -> Next;{error,E} -> R#{error => E,mix_ready => false} end;
start_playback(_,R) -> R.
enable_output(Id,#{descriptor := D,intent := I,context := #{deadline := Deadline}} = R) ->
    case ba_audio_mixer:add(Id,(ba_audio_opus:descriptor(D))#{authorization_deadline => Deadline},maps:get(gain,I)) of
        ok ->
            case ba_audio_mixer:enable(Id,true) of
                ok -> {ok,maps:remove(error,R#{mix_ready => true})};
                Error -> ba_audio_mixer:remove(Id),Error
            end;
        Error -> Error
    end.
catalog(Peer,#{catalogs := Cs} = S) ->
    case {maps:is_key(Peer,Cs),context(Peer)} of
        {false,{ok,#{session := Session}}} ->
            Id = fresh(),
            case send(Peer,Id,#{<<"kind">> => <<"catalog.read">>}) of
                ok -> {ok,S#{catalogs := Cs#{Peer => #{id => Id,session => Session,deadline => now_ms()+5000,offers => #{}}}}};
                Error -> {Error,S}
            end;
        _ -> {{error,no_session_or_pending},S}
    end.
refresh_all(S) ->
    case ba_swarm_membership:current() of
        {ok,#{policy := #{peers := Peers}}} -> maps:fold(fun(Peer,_,Acc) -> {_,Next}=catalog(Peer,Acc),Next end,S,Peers);
        _ -> S
    end.
context(Peer) -> try ba_swarm_control:audio_context(Peer) catch exit:_ -> {error,unavailable} end.
send(Peer,Id,P) -> ba_swarm_control:audio_message(Peer,Id,P).
wire(#{context := #{peer := Peer,session := Session,deadline := Deadline}},Id,P) ->
    Now = now_ms(),
    case context(Peer) of
        {ok,#{session := Session}} when Deadline>Now -> send(Peer,Id,P);
        _ -> {error,session_lost}
    end.
binding(R) -> #{<<"source">> => maps:get(source,R),<<"incarnation">> => maps:get(incarnation,R),<<"attempt">> => maps:get(attempt,R)}.
matches(#{peer := Peer,session := Session,swarm := Swarm},P,#{context := #{peer := Peer,session := Session,swarm := Swarm,deadline := Deadline}} = R) ->
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
closed(Id,R) ->
    _ = ba_audio_mixer:remove(Id),
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
reject(S) -> S#{rejected := maps:get(rejected,S)+1}.
fresh() -> binary:encode_hex(crypto:strong_rand_bytes(16)).
now_ms() -> erlang:monotonic_time(millisecond).
terminate(_,S) ->
    [stop_worker(P) || #{session := P} <- maps:values(maps:get(subscriptions,S)),is_pid(P)],
    [stop_worker(maps:get(session,R)) || R <- maps:values(maps:get(providers,S))],ok.

format_status(Status) -> maps:map(fun(state,S) -> maps:with([suspended,rejected],S);(log,_) -> [];(_,_) -> redacted end,Status).

resync_clock() ->
    Module = application:get_env(ba_core,audio_clock_adapter,ba_swarm_clock),
    try Module:resync() catch _:_ -> unavailable end.
