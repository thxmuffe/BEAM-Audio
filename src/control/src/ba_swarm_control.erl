%% Desk adapter. Owns application sessions, never OTP distribution or audio.
-module(ba_swarm_control).
-behaviour(gen_server).
-export([start_link/0, snapshot/0, connect/1, read_status/1,read_capabilities/1]).
-export([offer_job/2,retry_job/1,cancel_job/1,job_status/1,audio_message/3,audio_context/1,time_message/3]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, format_status/1]).

time_message(Peer,Id,Payload) -> gen_server:call(?MODULE,{time_message,Peer,Id,Payload}).
audio_message(Peer,Id,Payload) -> gen_server:call(?MODULE,{audio_message,Peer,Id,Payload}).
audio_context(Peer) -> gen_server:call(?MODULE,{audio_context,Peer}).

start_link() -> gen_server:start_link({local,?MODULE},?MODULE,[],[]).
snapshot() -> gen_server:call(?MODULE,snapshot).
connect(Peer) -> gen_server:call(?MODULE,{connect,Peer}).
read_status(Peer) -> gen_server:call(?MODULE,{read_status,Peer},7000).
read_capabilities(Peer) -> gen_server:call(?MODULE,{read_capabilities,Peer},7000).
offer_job(Peer,Offer) -> gen_server:call(?MODULE,{offer_job,Peer,Offer}).
retry_job(Id) -> gen_server:call(?MODULE,{job_command,retry,Id}).
cancel_job(Id) -> gen_server:call(?MODULE,{job_command,cancel,Id}).
job_status(Id) -> gen_server:call(?MODULE,{job_status,Id}).

init([]) ->
    %% This profile must be run without -name/-sname or a prestarted net_kernel.
    nonode@nohost = node(), undefined = whereis(net_kernel),
    process_flag(trap_exit,true),
    Identity = {Pub,_} = ba_device_store:identity(),
    Id = binary:encode_hex(Pub),
    Empty = #{swarm => binary:copy(<<"0">>,32),authority => Id,director => Id,
              epoch => 1,revision => 1,peers => #{}},
    View = case ba_swarm_membership:current() of
        {ok,V} -> V;
        _ -> #{policy => Empty,routes => #{},until => now_ms()}
    end,
    Config = maps:with([policy,routes],View),
    Protocol = (ba_swarm_control_protocol:new(Identity,maps:get(policy,View)))#{
        membership_deadline => maps:get(until,View)},
    erlang:send_after(250,self(),expire),
    {ok,#{protocol => Protocol,config => Config,callers => #{},jobs => #{},
          handler_requests => gen_server:reqids_new(),handler_monitor => monitor(process,whereis(ba_device_handler)),
          rejected => 0,last_rejection => null}}.

handle_call(snapshot,_,S) ->
    Public = ba_swarm_control_protocol:snapshot(maps:get(protocol,S)),
    {reply,Public#{relay => ba_swarm_desks:status(),membership => ba_swarm_membership:status(),rejected => maps:get(rejected,S),
        last_rejection => maps:get(last_rejection,S),jobs => maps:map(fun(_,J) -> public_job(J) end,maps:get(jobs,S))},S};
handle_call({audio_context,Peer},_,S) ->
    Result = try {ok,ba_swarm_control_protocol:context(Peer,now_ms(),maps:get(protocol,S))}
        catch _:_ -> {error,no_authorized_session} end,
    {reply,Result,S};
handle_call({time_message,Peer,Id,Payload},{Owner,_},S) ->
    case Owner=:=whereis(ba_swarm_clock) of
        false -> {reply,{error,not_clock_owner},S};
        true ->
            case ba_swarm_control_protocol:time_message(Peer,Id,Payload,now_ms(),maps:get(protocol,S)) of
                {ok,Packet,Protocol} ->
                    case send(Peer,Packet,S) of
                        ok -> {reply,ok,S#{protocol := Protocol}};
                        Error -> {reply,Error,S}
                    end;
                {error,R,_} -> {reply,{error,R},S}
            end
    end;
handle_call({audio_message,Peer,Id,Payload},{Owner,_},S) ->
    case Owner =:= whereis(ba_audio_receiver) of
        false -> {reply,{error,not_audio_owner},S};
        true ->
            case ba_swarm_control_protocol:audio_message(Peer,Id,Payload,now_ms(),maps:get(protocol,S)) of
                {ok,Packet,Protocol} ->
                    case send(Peer,Packet,S) of
                        ok -> {reply,ok,S#{protocol := Protocol}};
                        Error -> {reply,Error,S}
                    end;
                {error,R,_} -> {reply,{error,R},S}
            end
    end;
handle_call({job_status,Id},_,#{jobs := Jobs} = S) ->
    Result = case maps:find(Id,Jobs) of {ok,J} -> {ok,public_job(J)}; error -> {error,unknown_job} end,
    {reply,Result,S};
handle_call({offer_job,Peer,Offer},_,#{jobs := Jobs} = S) when map_size(Jobs) < 32 ->
    try
        ok = ba_swarm_job:validate_offer(Offer),
        Protocol = maps:get(protocol,S), Now = now_ms(),
        Context = ba_swarm_control_protocol:context(Peer,Now,Protocol),
        true = maps:get(id,Protocol) =:= maps:get(director,Context),
        Id = binary:encode_hex(crypto:strong_rand_bytes(16)),
        J = #{peer => Peer,session => maps:get(session,Context),offer => Offer,state => <<"offered">>,
              session_deadline => maps:get(deadline,Context),
              deadline => min(maps:get(deadline,Context),Now+5000),attempt => null,fenced => false},
        Next = transmit_job(Peer,<<"job.offer">>,Id,Offer,S#{jobs := Jobs#{Id => J}}),
        {reply,{ok,Id},Next}
    catch _:_ -> {reply,{error,invalid_or_unauthorized_job},S} end;
handle_call({offer_job,_,_},_,S) -> {reply,{error,job_limit},S};
handle_call({job_command,Command,Id},_,#{jobs := Jobs} = S) ->
    case maps:find(Id,Jobs) of
        error -> {reply,{error,unknown_job},S};
        {ok,#{peer := Peer,offer := Offer} = J} ->
            case {ba_swarm_job:terminal(maps:get(state,J)),Command} of
                {true,_} -> {reply,ok,S};
                {false,retry} ->
                    case now_ms() < maps:get(deadline,J) andalso not maps:get(fenced,J) of
                        true -> {reply,ok,transmit_job(Peer,<<"job.offer">>,Id,Offer,S)};
                        false -> {reply,{error,job_expired_or_fenced},S}
                    end;
                {false,cancel} ->
                    Next = S#{jobs := Jobs#{Id := J#{state := <<"cancel_pending">>,fenced := true}}},
                    {reply,ok,transmit_job(Peer,<<"job.cancel">>,Id,#{},Next)}
            end
    end;
handle_call({connect,Peer},_,S) ->
    case ba_swarm_control_protocol:connect(Peer,now_ms(),maps:get(protocol,S)) of
        {ok,Packet,Protocol} ->
            case send(Peer,Packet,S) of
                ok -> {reply,ok,S#{protocol := Protocol}};
                Error -> {reply,Error,S}
            end;
        {error,Reason,_} -> {reply,{error,Reason},S}
    end;
handle_call({Operation,Peer},From,#{callers := Callers} = S)
        when Operation =:= read_status; Operation =:= read_capabilities ->
    Result = case Operation of
        read_status -> ba_swarm_control_protocol:request_status(Peer,now_ms(),maps:get(protocol,S));
        read_capabilities -> ba_swarm_control_protocol:request_capabilities(Peer,now_ms(),maps:get(protocol,S))
    end,
    case Result of
        {ok,Packet,Protocol} ->
            case send(Peer,Packet,S) of
                ok -> {noreply,S#{protocol := Protocol,callers := Callers#{Peer => From}}};
                Error -> {reply,Error,S}
            end;
        {error,Reason,_} -> {reply,{error,Reason},S}
    end;
handle_call(_,_,S) -> {reply,{error,unsupported},S}.
handle_cast(_,S) -> {noreply,S}.

handle_info({membership_authorized,View},S) ->
    Config = maps:with([policy,routes],View),
    Next = case Config =:= maps:get(config,S) of
        true -> S;
        false ->
            Cleared = reset(policy_changed,S),
            Cleared#{config := Config,protocol := ba_swarm_control_protocol:new(
                ba_device_store:identity(),maps:get(policy,View))}
    end,
    {noreply,Next#{protocol := (maps:get(protocol,Next))#{membership_deadline => maps:get(until,View)}}};
handle_info(membership_invalidated,S) ->
    Next = reset(membership_invalidated,S),
    {noreply,Next#{protocol := (maps:get(protocol,Next))#{membership_deadline => now_ms()}}};
handle_info({desk_delivery,_,Peer,Packet},S0) ->
    S = S0#{received_at_ns => erlang:monotonic_time(nanosecond)},
    case now_ms() < maps:get(membership_deadline,maps:get(protocol,S)) of
        true ->
            case ba_swarm_control_protocol:receive_packet(Peer,Packet,now_ms(),maps:get(protocol,S)) of
                {ok,Packets,Events,Protocol} ->
                    Applied = lists:foldl(fun(E,Acc) -> event(Peer,E,Acc) end,S#{protocol := Protocol},Events),
                    Next = case Events of
                        [{job_report,_,_,_}] ->
                            case maps:get(rejected,Applied) > maps:get(rejected,S) of
                                true -> Applied#{protocol := maps:get(protocol,S)};
                                false -> Applied
                            end;
                        _ -> Applied
                    end,
                    case lists:all(fun(P) -> send(Peer,P,Next) =:= ok end,Packets) of
                        true -> {noreply,Next};
                        false -> {noreply,reset(transport_failed,Next)}
                    end;
                {error,Reason,_} -> {noreply,rejected(Reason,S)}
            end;
        false -> {noreply,rejected(membership_expired,S)}
    end;
handle_info({desk_event,_,disconnected},S) -> {noreply,reset(disconnected,S)};
handle_info({desk_event,URL,{presence,Online}},#{config := #{routes := Routes}} = S) ->
    Peers = maps:keys(maps:get(sessions,maps:get(protocol,S))),
    Next = lists:foldl(fun(Peer,Acc) ->
        case maps:find(Peer,Routes) of
            {ok,#{<<"desk">> := URL}} ->
                case lists:member(Peer,Online) of
                    true -> Acc;false -> close_peer(Peer,peer_disconnected,Acc)
                end;
            _ -> Acc
        end
    end,S,Peers),{noreply,Next};
handle_info({desk_event,_,_},S) -> {noreply,S};
handle_info(expire,S) ->
    {Events,Protocol} = ba_swarm_control_protocol:expire(now_ms(),maps:get(protocol,S)),
    Next = lists:foldl(fun({Peer,Reason},Acc) ->
        case Reason of
            session_expired ->
                Old = maps:get(Peer,maps:get(sessions,maps:get(protocol,S))),
                drop_session(Peer,maps:get(id,Old)),
                fence_peer_jobs(Peer,reply(Peer,{error,Reason},Acc));
            _ -> reply(Peer,{error,Reason},Acc)
        end
    end,S#{protocol := Protocol},Events),
    Final = expire_jobs(ensure_handler_monitor(Next)),
    erlang:send_after(250,self(),expire), {noreply,Final};
handle_info({'DOWN',Ref,process,_,_},#{handler_monitor := Ref} = S) ->
    {noreply,reset(handler_restarted,S#{handler_monitor := undefined})};
handle_info({job_report,Handler,Context,Id,Report},S) ->
    case Handler =:= whereis(ba_device_handler) of
        true -> {noreply,send_job_report(Context,Id,Report,S)};
        false -> {noreply,S}
    end;
handle_info(Message,#{handler_requests := Requests} = S) ->
    case gen_server:check_response(Message,Requests,true) of
        {{reply,{ok,Report}},{Context,Id},Rest} ->
            {noreply,send_job_report(Context,Id,Report,S#{handler_requests := Rest})};
        {{reply,_},_,Rest} -> {noreply,reset(handler_unavailable,S#{handler_requests := Rest})};
        {{error,_},_,Rest} -> {noreply,reset(handler_unavailable,S#{handler_requests := Rest})};
        _ -> {noreply,S}
    end.

send(Peer,Packet,_) -> ba_swarm_desks:send(Peer,<<"swarm_control">>,Packet).
event(Peer,{reply,<<"status.reply">>,Value},S) -> reply(Peer,{ok,Value},S);
event(Peer,{reply,<<"status.error">>,_},S) -> reply(Peer,{error,forbidden},S);
event(Peer,{reply,<<"capabilities.reply">>,Value},S) -> reply(Peer,{ok,Value},S);
event(Peer,{reply,<<"capabilities.error">>,#{<<"reason">> := Reason}},S) ->
    Error = case Reason of <<"forbidden">> -> forbidden; <<"unavailable">> -> unavailable end,
    reply(Peer,{error,Error},S);
event(Peer,{capabilities_read,Request},S) ->
    Value = try ba_device_handler:capabilities() catch exit:_ -> unavailable end,
    case ba_swarm_control_protocol:reply_capabilities(Peer,Request,Value,now_ms(),maps:get(protocol,S)) of
        {ok,Packet,Protocol} ->
            case send(Peer,Packet,S) of
                ok -> S#{protocol := Protocol};
                _ -> reset(transport_failed,S)
            end;
        {error,_,_} -> reset(capability_reply_failed,S)
    end;
event(_,{time,Id,Payload,Context},S) ->
    time_notify({swarm_time,Context#{received_at_ns => maps:get(received_at_ns,S)},Id,Payload}),S;
event(_,{audio,Id,Payload,Context},S) ->
    audio_notify({swarm_audio,Context,Id,Payload}),S;
event(_,{job,Operation,Id,Payload,Context},#{handler_requests := Requests} = S) ->
    case gen_server:reqids_size(Requests) < 32 of
        false -> send_job_report(Context,Id,ba_swarm_job:report(null,<<"rejected">>,<<"job_limit">>),S);
        true ->
            Request = case Operation of
                <<"job.offer">> -> {accept_job,Context,Id,Payload};
                <<"job.cancel">> -> {cancel_job,Context,Id}
            end,
            Ref = gen_server:send_request(ba_device_handler,Request),
            S#{handler_requests := gen_server:reqids_add(Ref,{Context,Id},Requests)}
    end;
event(_,{job_report,Id,Report,Context},S) -> receive_job_report(Context,Id,Report,S);
event(Peer,{session_replaced,Old},S) ->
    drop_session(Peer,Old),fence_peer_jobs(Peer,reply(Peer,{error,session_replaced},S));
event(_,authorized,S) -> S.
reply(Peer,Result,#{callers := Callers} = S) ->
    case maps:take(Peer,Callers) of
        {From,Rest} -> gen_server:reply(From,Result), S#{callers := Rest};
        error -> S
    end.
reset(Reason,#{callers := Callers,protocol := Protocol} = S) ->
    maps:foreach(fun(_,From) -> gen_server:reply(From,{error,Reason}) end,Callers),
    maps:foreach(fun(Peer,Session) -> drop_session(Peer,maps:get(id,Session)) end,maps:get(sessions,Protocol)),
    lists:foreach(fun({Ref,_}) -> try gen_server:receive_response(Ref,0) catch _:_ -> ok end end,
                  gen_server:reqids_to_list(maps:get(handler_requests,S))),
    Jobs = maps:map(fun(_,J) -> fence_job(J) end,maps:get(jobs,S)),
    S#{callers := #{},protocol := ba_swarm_control_protocol:reset(Protocol),
       handler_requests := gen_server:reqids_new(),jobs := Jobs}.
rejected(Reason,S) -> S#{rejected := maps:get(rejected,S)+1,last_rejection := Reason}.
now_ms() -> erlang:monotonic_time(millisecond).
terminate(_,S) ->
    _ = reset(stopped,S), ok.

%% OTP diagnostics must not dump the signing key or replay/handshake state.
format_status(Status) ->
    maps:map(fun(state,S) -> ba_swarm_control_protocol:snapshot(maps:get(protocol,S));
                (log,_) -> []; (_,_) -> redacted end,Status).

public_job(J) -> maps:with([peer,state,attempt,report],J).
transmit_job(Peer,Op,Id,Payload,#{jobs := Jobs,protocol := Protocol} = S) ->
    J = maps:get(Id,Jobs),
    try
        Context = ba_swarm_control_protocol:context(Peer,now_ms(),Protocol),
        true = maps:get(session,J) =:= maps:get(session,Context),
        {ok,Packet,NextProtocol} = ba_swarm_control_protocol:job_message(Peer,Op,Id,Payload,now_ms(),Protocol),
        case send(Peer,Packet,S) of
            ok -> S#{protocol := NextProtocol};
            _ -> S#{jobs := Jobs#{Id := fence_job(J)}}
        end
    catch _:_ -> S#{jobs := Jobs#{Id := fence_job(J)}} end.
send_job_report(#{peer := Peer,session := Session},Id,Report,#{protocol := Protocol} = S) ->
    try
        Session = maps:get(session,ba_swarm_control_protocol:context(Peer,now_ms(),Protocol)),
        {ok,Packet,Next} = ba_swarm_control_protocol:job_message(Peer,<<"job.report">>,Id,Report,now_ms(),Protocol),
        case send(Peer,Packet,S) of
            ok -> S#{protocol := Next};
            _ -> reset(transport_failed,S)
        end
    catch _:_ -> S end.
receive_job_report(#{peer := Peer,session := Session},Id,Report,#{jobs := Jobs} = S) ->
    case maps:find(Id,Jobs) of
        {ok,#{peer := Peer,session := Session} = J} ->
            Attempt = maps:get(<<"attempt">>,Report), State = maps:get(<<"state">>,Report),
            OldAttempt = maps:get(attempt,J),
            Fenced = maps:get(fenced,J) orelse now_ms() >= maps:get(deadline,J),
            Allowed = (OldAttempt =:= null orelse OldAttempt =:= Attempt) andalso
                (not Fenced orelse (State =/= <<"accepted">> andalso State =/= <<"completed">>)),
            Terminal = ba_swarm_job:terminal(maps:get(state,J)),
            case {Allowed,Terminal,maps:get(report,J,undefined) =:= Report} of
                {true,false,_} ->
                    Deadline = case {OldAttempt,State} of
                        {null,<<"accepted">>} -> min(maps:get(session_deadline,J),
                            now_ms()+maps:get(<<"lease_ms">>,maps:get(offer,J)));
                        _ -> maps:get(deadline,J)
                    end,
                    S#{jobs := Jobs#{Id := J#{attempt := Attempt,state := State,report => Report,deadline := Deadline}}};
                {_,true,true} -> S;
                _ -> rejected(stale_or_conflicting_report,S)
            end;
        _ -> rejected(unsolicited_job_report,S)
    end.
fence_job(J) ->
    case ba_swarm_job:terminal(maps:get(state,J)) of
        true -> J;
        false -> J#{state := <<"unconfirmed">>,fenced := true}
    end.
fence_peer_jobs(Peer,#{jobs := Jobs} = S) ->
    S#{jobs := maps:map(fun(_,#{peer := P} = J) -> case P =:= Peer of true -> fence_job(J); false -> J end end,Jobs)}.
close_peer(Peer,Reason,#{protocol := Protocol} = S) ->
    Sessions = maps:get(sessions,Protocol),
    case maps:find(Peer,Sessions) of
        {ok,Session} -> drop_session(Peer,maps:get(id,Session));
        error -> ok
    end,
    fence_peer_jobs(Peer,reply(Peer,{error,Reason},S#{protocol := Protocol#{sessions := maps:remove(Peer,Sessions),rekeys => maps:remove(Peer,maps:get(rekeys,Protocol,#{}))}})).
drop_session(Peer,Session) ->
    time_notify({time_session_down,Peer,Session}),
    audio_notify({audio_session_down,Peer,Session}),
    Ref = gen_server:send_request(ba_device_handler,{session_down,Peer,Session}),
    try gen_server:receive_response(Ref,0) catch _:_ -> ok end, ok.
ensure_handler_monitor(#{handler_monitor := undefined} = S) ->
    case whereis(ba_device_handler) of
        undefined -> S;
        Pid -> S#{handler_monitor := monitor(process,Pid)}
    end;
ensure_handler_monitor(S) -> S.
expire_jobs(#{jobs := Jobs} = S) ->
    lists:foldl(fun({Id,#{peer := Peer} = J},Acc) ->
        case not ba_swarm_job:terminal(maps:get(state,J)) andalso
             not maps:get(fenced,J) andalso now_ms() >= maps:get(deadline,J) of
            true ->
                Current = maps:get(jobs,Acc),
                transmit_job(Peer,<<"job.cancel">>,Id,#{},Acc#{jobs := Current#{Id := fence_job(J)}});
            false -> Acc
        end
    end,S,maps:to_list(Jobs)).

audio_notify(Event) ->
    case whereis(ba_audio_receiver) of
        undefined -> ok;
        Pid -> case process_info(Pid,message_queue_len) of
            {message_queue_len,N} when N < 64 -> Pid ! Event;
            _ -> ok
        end
    end.

time_notify(Event) ->
    case whereis(ba_swarm_clock) of
        undefined -> ok;
        Pid ->
            case Event of
                {time_session_down,_,_} -> Pid ! Event;
                _ -> case process_info(Pid,message_queue_len) of
                    {message_queue_len,N} when N<64 -> Pid ! Event;
                    _ -> ok
                end
            end
    end.
