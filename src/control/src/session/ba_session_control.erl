%% Desk adapter. Owns the authenticated links to peers, never OTP distribution or audio.
-module(ba_session_control).
-behaviour(gen_server).
-export([start_link/0, snapshot/0, connect/1, exclude/1, read_status/1,read_capabilities/1,read_capabilities/2]).
-export([session_request/2,introduce/1,audio_message/3,chat_message/3,audio_context/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, format_status/1]).
-define(BEHIND_MS,2000).

chat_message(Peer,Id,Text) -> gen_server:call(ba_session_scope:ref(?MODULE),{chat_message,Peer,Id,Text}).
audio_message(Peer,Id,Payload) -> gen_server:call(ba_session_scope:ref(?MODULE),{audio_message,Peer,Id,Payload}).
audio_context(Peer) -> gen_server:call(ba_session_scope:ref(?MODULE),{audio_context,Peer}).

%% One hello to a Device that should know this one (e.g. the Manager).
%% Asynchronous for the same reason as session_request/2.
introduce(Peer) -> gen_server:cast(ba_session_scope:ref(?MODULE),{introduce,Peer}).
%% Signed Session requests from membership to the Devices that execute them.
%% Asynchronous: membership is called by this process for snapshots.
session_request(Peers,Payload) -> gen_server:cast(ba_session_scope:ref(?MODULE),{session_request,Peers,Payload}).

start_link() -> gen_server:start_link(ba_session_scope:registration(?MODULE),?MODULE,[],[]).
snapshot() -> gen_server:call(ba_session_scope:ref(?MODULE),snapshot).
exclude(Peer) -> gen_server:call(ba_session_scope:ref(?MODULE),{exclude,Peer}).
connect(Peer) -> gen_server:call(ba_session_scope:ref(?MODULE),{connect,Peer}).
read_status(Peer) -> gen_server:call(ba_session_scope:ref(?MODULE),{read_status,Peer},7000).
read_capabilities(Peer) -> gen_server:call(ba_session_scope:ref(?MODULE),{read_capabilities,Peer},7000).
read_capabilities(Peer,Metrics) -> gen_server:call(ba_session_scope:ref(?MODULE),{read_capabilities,Peer,Metrics},7000).

init([]) ->
    %% This profile must be run without -name/-sname or a prestarted net_kernel.
    nonode@nohost = node(), undefined = ba_session_scope:whereis(net_kernel),
    process_flag(trap_exit,true),
    Identity = {Pub,_} = ba_device_store:identity(),
    Id = binary:encode_hex(Pub),
    %% No Session yet: an unusable placeholder (a join certificate from a
    %% throwaway invitation key) until membership installs the real one.
    {Invitation,Key} = ba_session_passport:invitation_key(binary:encode_hex(crypto:strong_rand_bytes(16))),
    None = binary:copy(<<"0">>,32),
    Empty = #{session => None,authority => Id,manager => Id,revision => 1,invitation => Invitation,
              join => ba_session_passport:join(None,Id,Key),members => #{},defaults => [],removed => []},
    View = case ba_session_membership:current() of
        {ok,V} -> V;
        _ -> #{policy => Empty,routes => #{},until => now_ms()}
    end,
    Config = maps:with([policy,routes,envelope],View),
    Protocol = (ba_session_control_protocol:new(Identity,maps:get(policy,View),now_ms()))#{
        membership_deadline => maps:get(until,View),lease_ms => ba_settings:app(control_link_lease_ms,60000)},
    erlang:send_after(250,self(),expire),
    {ok,#{protocol => Protocol,config => Config,callers => #{},peer_names => #{},
          rejected => 0,last_rejection => null}}.

handle_call(snapshot,_,S) ->
    Public = ba_session_control_protocol:snapshot(maps:get(protocol,S)),
    {reply,Public#{peer_errors => maps:with(maps:keys(maps:get(links,Public)),maps:get(peer_errors,S,#{})),peer_names => maps:with(maps:keys(maps:get(links,Public)),maps:get(peer_names,S)),relay => ba_session_desks:status(),membership => ba_session_membership:status(),rejected => maps:get(rejected,S),
        last_rejection => maps:get(last_rejection,S),diagnostics => ba_diagnostics:view(S)},S};
handle_call({exclude,Peer},_,#{protocol := P}=S) ->
    case maps:find(Peer,live(P)) of {ok,Link} -> drop_link(Peer,maps:get(id,Link));error -> ok end,
    Next=reply(Peer,{error,peer_excluded},S),
    {reply,ok,Next#{protocol := ba_session_control_protocol:close(Peer,now_ms(),P)}};
handle_call({chat_message,Peer,Id,Text},{Owner,_},S) ->
    case Owner=:=ba_session_scope:whereis(ba_session_chat) of
        false -> {reply,{error,not_chat_owner},S};
        true ->
            case ba_session_control_protocol:chat_message(Peer,Id,Text,now_ms(),maps:get(protocol,S)) of
                {ok,Packet,P} -> case send(Peer,Packet,S) of ok -> {reply,ok,S#{protocol := P}};Error -> {reply,Error,S} end;
                {error,R,_} -> {reply,{error,R},S}
            end
    end;
handle_call({audio_context,Peer},_,S) ->
    Result = try {ok,ba_session_control_protocol:context(Peer,now_ms(),maps:get(protocol,S))}
        catch _:_ -> {error,no_authorized_link} end,
    {reply,Result,S};
handle_call({audio_message,Peer,Id,Payload},{Owner,_},S) ->
    case Owner =:= ba_session_scope:whereis(ba_audio_receiver) of
        false -> {reply,{error,not_audio_owner},S};
        true ->
            case ba_session_control_protocol:audio_message(Peer,Id,Payload,now_ms(),maps:get(protocol,S)) of
                {ok,Packet,Protocol} ->
                    case send(Peer,Packet,S) of
                        ok -> {reply,ok,S#{protocol := Protocol}};
                        Error -> {reply,Error,S}
                    end;
                {error,R,_} -> {reply,{error,R},S}
            end
    end;
handle_call({connect,Peer},_,S) ->
    case ba_app_session:excluded(Peer) of true -> {reply,{error,peer_excluded},S};false -> connect_peer(Peer,S) end;

handle_call({read_capabilities,Peer,Metrics},From,S) when is_boolean(Metrics);is_map(Metrics) ->
    read_capabilities_call(Peer,Metrics,From,S);
handle_call({Operation,Peer},From,#{callers := Callers} = S)
        when Operation =:= read_status; Operation =:= read_capabilities ->
    Result = case Operation of
        read_status -> ba_session_control_protocol:request_status(Peer,now_ms(),maps:get(protocol,S));
        read_capabilities -> ba_session_control_protocol:request_capabilities(Peer,now_ms(),maps:get(protocol,S))
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
handle_cast({introduce,Peer},S) ->
    {_,_,Next} = connect_peer(Peer,S),{noreply,Next};
handle_cast({session_request,Peers,Payload},S) ->
    {noreply,lists:foldl(fun(Peer,Acc) ->
        Id = binary:encode_hex(crypto:strong_rand_bytes(16)),
        case ba_session_control_protocol:session_message(Peer,Id,Payload,now_ms(),maps:get(protocol,Acc)) of
            {ok,Packet,Protocol} ->
                case send(Peer,Packet,Acc) of
                    ok -> Acc#{protocol := Protocol};
                    _ -> ba_diagnostics:count(session_request_unsent,Acc#{protocol := Protocol})
                end;
            {error,_,_} -> ba_diagnostics:count(session_request_invalid,Acc)
        end
    end,S,Peers)};
handle_cast(_,S) -> {noreply,S}.

handle_info({membership_authorized,View},S) ->
    Config = maps:with([policy,routes,envelope],View),
    Old = maps:get(policy,maps:get(config,S)),New = maps:get(policy,View),
    Next = case {Config =:= maps:get(config,S),maps:get(session,Old)=:=maps:get(session,New)} of
        {true,_} -> S;
        %% Rights changed: checked per request from now on; nothing restarts.
        {false,true} -> S#{config := Config,protocol := ba_session_control_protocol:set_policy(New,maps:get(protocol,S))};
        {false,false} ->
            Cleared = reset(policy_changed,S),
            Cleared#{config := Config,protocol := ba_session_control_protocol:new(
                ba_device_store:identity(),New,now_ms())}
    end,
    {noreply,Next#{protocol := (maps:get(protocol,Next))#{membership_deadline => maps:get(until,View),
        lease_ms => ba_settings:app(control_link_lease_ms,60000)}}};
handle_info(membership_invalidated,S) ->
    Next = reset(membership_invalidated,S),
    {noreply,Next#{protocol := (maps:get(protocol,Next))#{membership_deadline => now_ms()}}};
handle_info({desk_delivery,_,Peer,Sealed},S) ->
    Packet = try
        #{envelope := Key,policy := #{session := Session}} = maps:get(config,S),
        ba_session_passport:open_envelope(Key,Session,Sealed)
    catch _:_ -> envelope_rejected end,
    case Packet=/=envelope_rejected andalso now_ms() < maps:get(membership_deadline,maps:get(protocol,S)) of
        true ->
            case ba_session_control_protocol:receive_packet(Peer,Packet,now_ms(),maps:get(protocol,S)) of
                {ok,Packets,Events,Protocol} ->
                    Next = behind(Peer,lists:foldl(fun(E,Acc) -> event(Peer,E,Acc) end,S#{protocol := Protocol},Events)),
                    case lists:all(fun(P) -> send(Peer,P,Next) =:= ok end,Packets) of
                        true -> {noreply,Next};
                        false -> {noreply,rejected(transport_failed,Next)}
                    end;
                {error,Reason,_} -> {noreply,rejected(Reason,S)}
            end;
        false -> {noreply,rejected(case Packet of envelope_rejected -> envelope_rejected;_ -> membership_expired end,S)}
    end;
handle_info({discover_name,Peer},S) -> {noreply,discover_name(Peer,S)};
handle_info({desk_event,_,disconnected},S) -> {noreply,S};
handle_info({desk_event,_,_},S) -> {noreply,S};
handle_info(expire,S) ->
    {Events,Protocol} = ba_session_control_protocol:expire(now_ms(),maps:get(protocol,S)),
    Next = lists:foldl(fun({Peer,Reason},Acc) ->
        case Reason of
            link_expired ->
                Old = maps:get(Peer,maps:get(links,maps:get(protocol,S))),
                drop_link(Peer,maps:get(id,Old)),
                reply(Peer,{error,Reason},Acc);
            _ -> reply(Peer,{error,Reason},Acc)
        end
    end,S#{protocol := Protocol},Events),
    %% Nothing here contacts peers: relationships start with an actual request.
    erlang:send_after(250,self(),expire), {noreply,Next};
handle_info(_,S) -> {noreply,S}.

read_capabilities_call(Peer,Metrics,From,#{callers := Callers}=S) ->
    case ba_session_control_protocol:request_capabilities(Peer,Metrics,now_ms(),maps:get(protocol,S)) of
        {ok,Packet,Protocol} -> case send(Peer,Packet,S) of
            ok -> {noreply,S#{protocol := Protocol,callers := Callers#{Peer => From}}};
            Error -> {reply,Error,S}
        end;
        {error,R,_} -> {reply,{error,R},S}
    end.

%% Every Session message is sealed end to end; Reception routes opaque bytes.
send(Peer,Packet,#{config := #{envelope := Key,policy := #{session := Session}}}) ->
    ba_session_desks:send(Peer,<<"session_control">>,ba_session_passport:seal_envelope(Key,Session,Packet));
send(_,_,_) -> {error,no_link}.
event(Peer,{reply,<<"status.reply">>,Value},S) -> reply(Peer,{ok,Value},S);
event(Peer,{reply,<<"status.error">>,_},S) -> reply(Peer,{error,forbidden},S);
event(Peer,{reply,<<"capabilities.reply">>,Value},S) ->
    Names=maps:get(peer_names,S),
    Next=case maps:find(<<"device_name">>,Value) of
        {ok,Name} -> ba_contacts:observe_name(Peer,Name),gen_server:cast(ba_session_scope:ref(ba_session),{peer_name,Peer,Name}),S#{peer_names := Names#{Peer => Name}};
        error -> S#{peer_names := maps:remove(Peer,Names)}
    end,
    HasError=lists:any(fun(E) -> maps:get(<<"state">>,E,<<>>)=:=<<"error">> end,
        maps:values(maps:get(<<"audio">>,Value,#{}))),
    Errors=maps:get(peer_errors,Next,#{}),
    reply(Peer,{ok,Value},Next#{peer_errors => Errors#{Peer => HasError}});
event(Peer,{reply,<<"capabilities.error">>,#{<<"reason">> := Reason}},S) ->
    Error = case Reason of <<"forbidden">> -> forbidden; <<"unavailable">> -> unavailable end,
    reply(Peer,{error,Error},S);
event(Peer,{capabilities_read,Request,true,Options},S) ->
    {ok,_}=ba_audio_diagnostics:configure(Options,Peer),
    event(Peer,{capabilities_read,Request,true},S);
event(Peer,{capabilities_read,Request},S) -> event(Peer,{capabilities_read,Request,false},S);
event(Peer,{capabilities_read,Request,Metrics},S) ->
    %% Inspecting levels/analysis needs this Device's calibration consent; an Ask
    %% policy raises a request naming the reading Device. The reply never waits.
    case Metrics of true -> _=ba_audio_diagnostics:configure(#{<<"meters">> => true},Peer);false -> ok end,
    Value = try ba_device_handler:capabilities(Metrics) catch exit:_ -> unavailable end,
    case ba_session_control_protocol:reply_capabilities(Peer,Request,Value,now_ms(),maps:get(protocol,S)) of
        {ok,Packet,Protocol} ->
            case send(Peer,Packet,S) of
                ok -> S#{protocol := Protocol};
                _ -> rejected(transport_failed,S)
            end;
        {error,Reason,_} when Value=/=unavailable ->
            %% Our own reply is not valid on the wire. That is a local bug, not a
            %% reason to drop every link: say so, and tell this peer "unavailable".
            logger:error("Capabilities reply to a peer was not valid (~p); replying unavailable.",[Reason]),
            case ba_session_control_protocol:reply_capabilities(Peer,Request,unavailable,now_ms(),maps:get(protocol,S)) of
                {ok,Packet,Protocol} -> case send(Peer,Packet,S) of ok -> S#{protocol := Protocol};_ -> rejected(transport_failed,S) end;
                {error,_,_} -> rejected(capability_reply_failed,S)
            end;
        {error,_,_} -> rejected(capability_reply_failed,S)
    end;
event(_,{chat,Id,Text,Context},S) ->
    case ba_session_scope:whereis(ba_session_chat) of
        undefined -> S;
        P -> case process_info(P,message_queue_len) of
            {message_queue_len,N} when N<64 -> P ! {session_chat,Context,Id,Text},S;
            _ -> ba_diagnostics:count(chat_mailbox_overloaded,S)
        end
    end;
event(_,{audio,Id,Payload,Context},S) ->
    case audio_notify({session_audio,Context,Id,Payload}) of
        {error,overloaded} -> ba_diagnostics:count(audio_owner_overloaded,S);
        _ -> S
    end;
event(Peer,{session,_,Payload,_},S) ->
    gen_server:cast(ba_session_scope:ref(ba_session_membership),{session_request,Peer,Payload}),S;
event(Peer,{link_replaced,Old},S) ->
    drop_link(Peer,Old),reply(Peer,{error,link_replaced},S);
event(_,{link_renewed,Context},S) ->
    audio_notify({audio_link_renewed,Context}),S;
event(Peer,authorized,S) ->
    Context=ba_session_control_protocol:context(Peer,now_ms(),maps:get(protocol,S)),
    critical_audio_notify({audio_link_up,Context}),
    Revision = ba_session_control_protocol:peer_revision(Peer,maps:get(protocol,S)),
    gen_server:cast(ba_session_scope:ref(ba_session_membership),{encountered,Peer,Revision}),
    self() ! {discover_name,Peer},S.

%% Every packet carries its sender's statement revision. A linked peer that is
%% behind missed a change (sharing is a single send): share it again, at most
%% every ?BEHIND_MS per peer, so a lost update heals on ordinary traffic.
behind(Peer,#{protocol := P}=S) ->
    Mine = maps:get(revision,maps:get(policy,P)),Now = now_ms(),
    Told = maps:get(told_behind,S,#{}),
    case ba_session_control_protocol:peer_revision(Peer,P) < Mine andalso
         Now-maps:get(Peer,Told,Now-?BEHIND_MS) >= ?BEHIND_MS of
        true ->
            gen_server:cast(ba_session_scope:ref(ba_session_membership),{behind,Peer}),
            S#{told_behind => (maps:filter(fun(_,T) -> Now-T < ?BEHIND_MS end,Told))#{Peer => Now}};
        false -> S
    end.

discover_name(Peer,S) ->
    %% One asynchronous ordinary capability read when a peer's relationship
    %% starts. Snapshots consume the result without making UI polling wait.
    Names=maps:remove(Peer,maps:get(peer_names,S)),
    case ba_session_control_protocol:request_capabilities(Peer,now_ms(),maps:get(protocol,S)) of
        {ok,Packet,P} -> _=send(Peer,Packet,S),S#{protocol := P,peer_names := Names};
        _ -> S#{peer_names := Names}
    end.
reply(Peer,Result,#{callers := Callers} = S) ->
    case maps:take(Peer,Callers) of
        {From,Rest} -> gen_server:reply(From,Result), S#{callers := Rest};
        error -> S
    end.
reset(Reason,#{callers := Callers,protocol := Protocol} = S) ->
    maps:foreach(fun(_,From) -> gen_server:reply(From,{error,Reason}) end,Callers),
    maps:foreach(fun(Peer,Link) -> drop_link(Peer,maps:get(id,Link)) end,live(Protocol)),
    S#{callers := #{},peer_names := #{},peer_errors => #{},protocol := ba_session_control_protocol:reset(Protocol,now_ms())}.
rejected(Reason,S) -> ba_diagnostics:count(Reason,S#{rejected := maps:get(rejected,S)+1,last_rejection := Reason}).
now_ms() -> erlang:monotonic_time(millisecond).
terminate(_,S) ->
    _ = reset(stopped,S), ok.

%% OTP diagnostics must not dump the signing key or replay/handshake state.
format_status(Status) ->
    maps:map(fun(state,S) -> ba_session_control_protocol:snapshot(maps:get(protocol,S));
                (log,_) -> []; (_,_) -> redacted end,Status).

drop_link(Peer,Link) ->
    audio_notify({audio_link_down,Peer,Link}),ok.
audio_notify({audio_link_down,_,_}=Event) -> critical_audio_notify(Event);
audio_notify({audio_link_renewed,_}=Event) -> critical_audio_notify(Event);
audio_notify(Event) ->
    case ba_session_scope:whereis(ba_audio_receiver) of
        undefined -> ok;
        Pid -> case process_info(Pid,message_queue_len) of
            {message_queue_len,N} when N < 64 -> Pid ! Event,ok;
            _ -> {error,overloaded}
        end
    end.


critical_audio_notify(Event) ->
    case ba_session_scope:whereis(ba_audio_receiver) of undefined -> ok;P -> P ! Event,ok end.

connect_peer(Peer,S) ->
    case ba_session_control_protocol:connect(Peer,now_ms(),maps:get(protocol,S)) of
        {ok,Packet,Protocol} ->
            case send(Peer,Packet,S) of
                ok -> {reply,ok,S#{protocol := Protocol}};
                Error -> {reply,Error,S}
            end;
        {error,Reason,_} -> {reply,{error,Reason},S}
    end.

%% Relationships whose lapse has already been reported are closed.
live(Protocol) -> maps:filter(fun(_,R) -> not maps:get(lapsed,R,false) end,maps:get(links,Protocol)).
