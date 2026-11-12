%% Fixed local audio Worker. Existing scoped Streams are the audio job protocol.
%% Consent/Contracts are local; publication and receiving never enable each other.
-module(ba_device_audio).
-behaviour(gen_server).
-export([start_link/1,changed/1]).
-export([init/1,handle_call/3,handle_cast/2,handle_info/2,terminate/2]).
start_link(Owner) -> gen_server:start_link(?MODULE,Owner,[]).
changed(Pid) -> gen_server:cast(Pid,changed).
init(Owner) ->
    process_flag(trap_exit,true),monitor(process,Owner),self() ! tick,
    {ok,#{owner => Owner,contracts => [],connecting => #{},errors => #{}}}.
handle_call(_,_,S) -> {reply,{error,unsupported},S}.
handle_cast(changed,S) -> {noreply,reconcile(S#{errors := #{}})};
handle_cast(_,S) -> {noreply,S}.
handle_info(tick,S) -> erlang:send_after(250,self(),tick),{noreply,reconcile(S)};
handle_info({'DOWN',_,process,_,_},S) -> {stop,normal,S};
handle_info(_,S) -> {noreply,S}.
reconcile(S) ->
    Requested=ba_app_session:consent(),
    Roles=maps:get(roles,ba_buffee_membership:status(),[]),
    Desired=Requested#{broadcast := maps:get(broadcast,Requested) andalso lists:member(chef,Roles)},
    Consent=case application:get_env(ba_core,audio_suspended,false) of
        true -> maps:map(fun(_,_) -> false end,Desired);false -> Desired
    end,Adapter=application:get_env(ba_core,audio_capture_adapter,ba_mac_audio),
    [Adapter:stop(K) || K <- [microphone,broadcast],not maps:get(K,Consent),maps:get(state,Adapter:status(K))=/=stopped],
    case ba_buffee_membership:current() of
        {ok,#{policy := #{buffee := Buffee,peers := Peers},routes := _}} ->
            ok=ba_audio_sup:ensure_started(),
            Connected=connect_peers(maps:keys(Peers),S),
            Captured=lists:foldl(fun(K,Acc) -> capture(K,maps:get(K,Consent),Adapter,Acc) end,Connected,[microphone,broadcast]),
            View=ba_audio_receiver:snapshot(),
            {Pub,_}=ba_device_store:identity(),Self=binary:encode_hex(Pub),
            Local=[ba_audio:describe(P) || P <- ba_audio:sources()],
            Publish=[{publish,P,maps:get(source_key,O),ba_app_session:contract(Buffee,Self,#{receiver => P,source => maps:get(source_key,O)})}
                || P <- maps:keys(Peers),not ba_app_session:excluded(P),O <- Local],
            Offers=[O || O <- maps:get(offers,View),not ba_app_session:excluded(maps:get(device,O))],
            Receive=case maps:get(speaker,Consent) of
                true -> [{receive_audio,maps:get(device,O),maps:get(source_key,O),
                    ba_app_session:contract(Buffee,maps:get(device,O),#{receiver => Self,source => maps:get(source_key,O)})} || O <- Offers];
                false -> []
            end,
            Wanted=lists:sublist(Publish++Receive,32),
            [ba_audio_receiver:clear_contract(D,P,K) || {D,P,K,_}=C <- maps:get(contracts,S),not lists:member(C,Wanted)],
            [ba_audio_receiver:set_contract(D,P,K,C,1) || {D,P,K,C} <- Wanted],
            Subs=maps:get(subscriptions,View),
            [ba_audio_receiver:stop(Id) || {Id,I} <- maps:to_list(Subs),
                not maps:get(speaker,Consent) orelse ba_app_session:excluded(maps:get(device,I))],
            Playback=case maps:get(speaker,Consent) of
                false -> [];
                true ->
                    [begin P=maps:get(device,O),K=maps:get(source_key,O),
                        case lists:any(fun(I) -> maps:get(device,I)=:=P andalso maps:get(source_key,I)=:=K end,maps:values(Subs)) of
                            false -> ba_audio_receiver:subscribe(P,K,channel);true -> ok
                        end
                    end || O <- Offers],
                    [ba_audio_receiver:playback(Id,start) || {Id,#{state := active,playing := false}} <- maps:to_list(Subs)]
            end,
            NextView=ba_audio_receiver:snapshot(),
            Speaker=case maps:get(speaker,Consent) of
                false -> #{state => disabled};
                true ->
                    Failures=[R || {error,R} <- Playback]++[maps:get(error,I) || I <- maps:values(maps:get(subscriptions,NextView)),
                        maps:get(playing,I,false),maps:is_key(error,I)],
                    Playing=lists:any(fun(I) -> maps:get(playing,I,false) andalso maps:get(state,I)=:=active andalso maps:get(mix_ready,I,false) end,
                        maps:values(maps:get(subscriptions,NextView))),
                    case Failures of
                        [Reason|_] -> #{state => error,error => printable(Reason)};
                        [] -> #{state => case Playing of true -> running;false -> ready end}
                    end
            end,
            Audio0=(maps:get(audio,Captured,#{}))#{speaker => Speaker#{meter => maps:get(receive_meter,NextView,#{})}},
            Audio=case maps:get(broadcast,Requested) andalso not lists:member(chef,Roles) of
                true -> Audio0#{broadcast => #{state => waiting_for_role,error => <<"An Owner must authorize this Device as a Chef.">>}};
                false -> Audio0
            end,
            Diagnostics=ba_audio_diagnostics:snapshot(NextView,ba_buffee_clock:status()),
            maps:get(owner,S) ! {audio_state,self(),Audio,Diagnostics},Captured#{contracts := Wanted};
        _ ->
            Audio=maps:map(fun(_,B) -> #{state => case B of true -> waiting_for_membership;false -> disabled end} end,Consent),
            maps:get(owner,S) ! {audio_state,self(),Audio,ba_audio_diagnostics:snapshot(#{},ba_buffee_clock:status())},S
    end.
capture(K,false,_,S) -> S#{audio => (maps:get(audio,S,#{}))#{K => #{state => disabled}}};
capture(K,true,Adapter,S) ->
    Status=Adapter:status(K),State=maps:get(state,Status),
    Result=case {State,maps:find(K,maps:get(errors,S)),ba_audio_input:ready()} of
        {error,_,_} -> Status;
        {_,{ok,E},_} -> #{state => error,error => E};
        {stopped,_,ok} ->
            case Adapter:start(K) of ok -> #{state => starting};{error,waiting_for_clock} -> #{state => waiting_for_clock};{error,R} -> #{state => error,error => printable(R)} end;
        {stopped,_,_} -> #{state => waiting_for_clock};
        _ -> Status
    end,
    Errors=case Result of #{state := error,error := Reason} -> (maps:get(errors,S))#{K => Reason};_ -> maps:get(errors,S) end,
    S#{audio => (maps:get(audio,S,#{}))#{K => Result},errors := Errors}.
connect_peers(Peers,S) ->
    {Pub,_}=ba_device_store:identity(),Self=binary:encode_hex(Pub),Now=erlang:monotonic_time(millisecond),
    Due=lists:foldl(fun(P,Acc) ->
        case Self<P andalso not ba_app_session:excluded(P) andalso Now>=maps:get(P,Acc,Now) of
            true ->
                case ba_buffee_control:audio_context(P) of {ok,_} -> ok;_ -> ba_buffee_control:connect(P) end,
                Acc#{P => Now+2000};
            false -> Acc
        end
    end,maps:get(connecting,S),Peers),S#{connecting := Due}.
printable(R) when is_binary(R) -> R;
printable(R) -> iolist_to_binary(io_lib:format("~p",[R])).
terminate(_,_) ->
    Adapter=application:get_env(ba_core,audio_capture_adapter,ba_mac_audio),
    [try Adapter:stop(K) catch exit:_ -> ok end || K <- [microphone,broadcast]],
    case ba_session_scope:whereis(ba_audio_receiver) of undefined -> ok;_ -> try ba_audio_receiver:stop() catch exit:_ -> ok end end,ok.
