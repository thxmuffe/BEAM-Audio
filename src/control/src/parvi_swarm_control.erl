%% Step-2 Desk adapter. Owns application sessions, never OTP distribution or audio.
-module(parvi_swarm_control).
-behaviour(gen_server).
-export([start_link/0, snapshot/0, connect/1, read_status/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, format_status/1]).

start_link() -> gen_server:start_link({local,?MODULE},?MODULE,[],[]).
snapshot() -> gen_server:call(?MODULE,snapshot).
connect(Peer) -> gen_server:call(?MODULE,{connect,Peer}).
read_status(Peer) -> gen_server:call(?MODULE,{read_status,Peer},7000).

init([]) ->
    %% This profile must be run without -name/-sname or a prestarted net_kernel.
    nonode@nohost = node(), undefined = whereis(net_kernel),
    process_flag(trap_exit,true),
    {ok,#{policy := Policy,mailbox := Mailbox,routes := Routes} = Config} =
        application:get_env(parvi,swarm_control),
    [mailbox,policy,routes] = lists:sort(maps:keys(Config)),
    Identity = parvi_cluster_store:identity(),
    Protocol = parvi_swarm_control_protocol:new(Identity,Policy),
    true = valid_cap(Mailbox),
    true = lists:sort(maps:keys(Routes)) =:= lists:sort(maps:keys(maps:get(peers,Policy))),
    maps:foreach(fun(_,Cap) -> true = valid_cap(Cap) end,Routes),
    {ok,Relay} = parvi_relay:start_link(#{owner => self(),delivery => raw,identity => Identity,
                                        max_owner_queue => 64}),
    parvi_relay:open(maps:get(swarm,Policy),Mailbox),
    parvi_relay:watch(maps:keys(Routes)),
    erlang:send_after(250,self(),expire),
    {ok,#{protocol => Protocol,relay => Relay,config => Config,callers => #{},
          rejected => 0,last_rejection => null}}.

handle_call(snapshot,_,S) ->
    Public = parvi_swarm_control_protocol:snapshot(maps:get(protocol,S)),
    {reply,Public#{relay => parvi_relay:status(),rejected => maps:get(rejected,S),
        last_rejection => maps:get(last_rejection,S)},S};
handle_call({connect,Peer},_,S) ->
    case parvi_swarm_control_protocol:connect(Peer,now_ms(),maps:get(protocol,S)) of
        {ok,Packet,Protocol} ->
            case send(Peer,Packet,S) of
                ok -> {reply,ok,S#{protocol := Protocol}};
                Error -> {reply,Error,S}
            end;
        {error,Reason,_} -> {reply,{error,Reason},S}
    end;
handle_call({read_status,Peer},From,#{callers := Callers} = S) ->
    case parvi_swarm_control_protocol:request_status(Peer,now_ms(),maps:get(protocol,S)) of
        {ok,Packet,Protocol} ->
            case send(Peer,Packet,S) of
                ok -> {noreply,S#{protocol := Protocol,callers := Callers#{Peer => From}}};
                Error -> {reply,Error,S}
            end;
        {error,Reason,_} -> {reply,{error,Reason},S}
    end;
handle_call(_,_,S) -> {reply,{error,unsupported},S}.
handle_cast(_,S) -> {noreply,S}.

handle_info({relay,{delivery,Peer,Cap,Payload}},#{config := #{mailbox := Cap,
            policy := #{swarm := Swarm}}} = S) ->
    case Payload of
        #{<<"type">> := <<"swarm_control">>,<<"swarm">> := Swarm,<<"packet">> := Packet}
                when map_size(Payload) =:= 3 ->
            case parvi_swarm_control_protocol:receive_packet(Peer,Packet,now_ms(),maps:get(protocol,S)) of
                {ok,Packets,Events,Protocol} ->
                    Next = lists:foldl(fun(E,Acc) -> event(Peer,E,Acc) end,S#{protocol := Protocol},Events),
                    case lists:all(fun(P) -> send(Peer,P,Next) =:= ok end,Packets) of
                        true -> {noreply,Next};
                        false -> {noreply,reset(transport_failed,Next)}
                    end;
                {error,Reason,_} -> {noreply,rejected(Reason,S)}
            end;
        _ -> {noreply,rejected(invalid_route,S)}
    end;
handle_info({relay,disconnected},S) -> {noreply,reset(disconnected,S)};
handle_info({relay,_},S) -> {noreply,S};
handle_info(expire,S) ->
    {Events,Protocol} = parvi_swarm_control_protocol:expire(now_ms(),maps:get(protocol,S)),
    Next = lists:foldl(fun({Peer,Reason},Acc) -> reply(Peer,{error,Reason},Acc) end,
                      S#{protocol := Protocol},Events),
    erlang:send_after(250,self(),expire), {noreply,Next};
handle_info({'EXIT',Relay,Reason},#{relay := Relay} = S) -> {stop,{relay_stopped,Reason},S};
handle_info(_,S) -> {noreply,S}.

send(Peer,Packet,#{config := #{routes := Routes,policy := #{swarm := Swarm}}}) ->
    parvi_relay:send(Peer,maps:get(Peer,Routes),
        #{<<"type">> => <<"swarm_control">>,<<"swarm">> => Swarm,<<"packet">> => Packet}).
event(Peer,{reply,<<"status.reply">>,Value},S) -> reply(Peer,{ok,Value},S);
event(Peer,{reply,<<"status.error">>,_},S) -> reply(Peer,{error,forbidden},S);
event(_,authorized,S) -> S.
reply(Peer,Result,#{callers := Callers} = S) ->
    case maps:take(Peer,Callers) of
        {From,Rest} -> gen_server:reply(From,Result), S#{callers := Rest};
        error -> S
    end.
reset(Reason,#{callers := Callers,protocol := Protocol} = S) ->
    maps:foreach(fun(_,From) -> gen_server:reply(From,{error,Reason}) end,Callers),
    S#{callers := #{},protocol := parvi_swarm_control_protocol:reset(Protocol)}.
rejected(Reason,S) -> S#{rejected := maps:get(rejected,S)+1,last_rejection := Reason}.
valid_cap(B) when is_binary(B),byte_size(B) =:= 32 ->
    re:run(B,<<"^[0-9A-F]+$">>,[{capture,none}]) =:= match;
valid_cap(_) -> false.
now_ms() -> erlang:monotonic_time(millisecond).
terminate(_,S) ->
    _ = reset(stopped,S),
    try gen_server:stop(maps:get(relay,S)) catch exit:_ -> ok end, ok.

%% OTP diagnostics must not dump the signing key or replay/handshake state.
format_status(Status) ->
    maps:map(fun(state,S) -> parvi_swarm_control_protocol:snapshot(maps:get(protocol,S));
                (log,_) -> []; (_,_) -> redacted end,Status).
