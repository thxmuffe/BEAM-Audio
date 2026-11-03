%% BEAM-owned direct transport. ex_webrtc implements ICE/DTLS/data channels;
%% this worker only binds authenticated Parvi identities to those connections.
-module(parvi_direct).
-behaviour(gen_server).
-export([start_link/0, sync/1, incoming/2, send/3, snapshot/0, peers/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).
start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).
sync(Routes) -> gen_server:cast(?MODULE, {sync, Routes}).
incoming(Peer, Signal) -> gen_server:cast(?MODULE, {incoming, Peer, Signal}).
send(Peer, _Cap, Payload) -> gen_server:call(?MODULE, {send, Peer, Payload}).
snapshot() -> gen_server:call(?MODULE, snapshot).
peers() -> gen_server:call(?MODULE, peers).
init([]) ->
    process_flag(trap_exit, true),
    Enabled = case code:ensure_loaded('Elixir.ExWebRTC.PeerConnection') of
        {module, _} -> case application:ensure_all_started(parvi_transport) of {ok, _} -> true; _ -> false end;
        _ -> false
    end,
    erlang:send_after(30000, self(), retry),
    {ok, #{enabled => Enabled, routes => #{}, connections => #{}, ready => []}}.
handle_call(peers, _, #{ready := Ready} = S) -> {reply, Ready, S};
handle_call(snapshot, _, #{enabled := Enabled, ready := Ready} = S) ->
    {reply, #{enabled => Enabled, peers => Ready}, S};
handle_call({send, Peer, Payload}, _, #{ready := Ready, connections := PCs} = S) ->
    Reply = case {lists:member(Peer, Ready), maps:find(Peer, PCs)} of
        {true, {ok, Pid}} ->
            try parvi_peer_connection:send_packet(Pid, iolist_to_binary(json:encode(Payload)))
            catch exit:_ -> {error, unavailable} end;
        _ -> {error, unavailable}
    end,
    {reply, Reply, S};
handle_call(_, _, S) -> {reply, {error, unsupported}, S}.
handle_cast({sync, Routes}, #{routes := Old, ready := Ready, connections := PCs} = S) ->
    Removed = maps:keys(Old) -- maps:keys(Routes),
    [close(maps:get(P, PCs, undefined)) || P <- Removed],
    Next = S#{routes := Routes, ready := Ready -- Removed, connections := maps:without(Removed, PCs)},
    {noreply, lists:foldl(fun connect/2, Next, maps:keys(Routes) -- maps:keys(Old))};
handle_cast({incoming, Peer, Signal}, #{connections := PCs} = S) ->
    case maps:find(Peer, PCs) of
        {ok, Pid} -> parvi_peer_connection:signal(Pid, Signal);
        error -> ok
    end,
    {noreply, S};
handle_cast(_, S) -> {noreply, S}.
handle_info({parvi_direct, Pid, Event}, #{connections := PCs} = S) ->
    case [N || {N, P} <- maps:to_list(PCs), P =:= Pid] of
        [Peer] -> {noreply, event(Peer, Event, S)};
        [] -> {noreply, S}
    end;
handle_info({'EXIT', Pid, _}, #{connections := PCs, ready := Ready} = S) ->
    Gone = [N || {N, P} <- maps:to_list(PCs), P =:= Pid],
    {noreply, S#{connections := maps:without(Gone, PCs), ready := Ready -- Gone}};
handle_info(retry, #{enabled := Enabled, routes := Routes, ready := Ready, connections := PCs} = S) ->
    erlang:send_after(30000, self(), retry),
    Retry = case Enabled andalso maps:get(connected, parvi_relay:status()) of
        true -> maps:keys(Routes) -- Ready; false -> []
    end,
    [close(maps:get(P, PCs, undefined)) || P <- Retry],
    {noreply, lists:foldl(fun connect/2, S#{connections := maps:without(Retry, PCs)}, Retry)};
handle_info(_, S) -> {noreply, S}.
connect(Peer, #{enabled := true, connections := PCs} = S) ->
    case parvi_peer_connection:start_link(self(), parvi_relay:id() < Peer,
            application:get_env(parvi, direct_stun_urls, [])) of
        {ok, Pid} -> S#{connections := PCs#{Peer => Pid}};
        _ -> S
    end;
connect(_, S) -> S.
event(Peer, {signal, Signal}, #{routes := Routes} = S) ->
    #{swarm := Id, mailbox := Cap, member := Member} = maps:get(Peer, Routes),
    case parvi_swarm_wire:valid_signal(Signal) of
        true -> parvi_relay:send(Peer, Cap, parvi_swarm_wire:encode(Id, {rtc, Id, Member, Signal}));
        false -> ok
    end, S;
event(Peer, {ready, Ready}, #{ready := Peers} = S) ->
    S#{ready := case Ready of true -> lists:usort([Peer | Peers]); false -> lists:delete(Peer, Peers) end};
event(Peer, {packet, Data}, #{ready := Ready} = S) when byte_size(Data) =< 131072 ->
    try
        true = lists:member(Peer, Ready),
        case parvi_swarm_wire:decode(json:decode(Data)) of
            {ok, _, {rtc, _, _, _}} -> ok;
            {ok, _, Event} -> whereis(parvi_swarms) ! {relay, {delivery, Peer, Event}};
            _ -> ok
        end
    catch _:_ -> ok end, S;
event(_, _, S) -> S.
close(undefined) -> ok;
close(Pid) -> parvi_peer_connection:close(Pid).
