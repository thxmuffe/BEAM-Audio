%% Portable, observation-based network state for app interfaces.
%% Checks never run on the bridge or UI process. Unknown does not mean dead.
-module(parvi_network).
-behaviour(gen_server).
-export([start_link/0, snapshot/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).
snapshot() ->
    case parvi_relay:enabled() of
        true -> relay_snapshot();
        false -> direct_snapshot()
    end.
relay_snapshot() ->
    #{id := Id, online := Online, watched := Watched} = parvi_relay:status(),
    Swarms = parvi_swarms:snapshot(),
    Direct = parvi_direct:peers(),
    Members = lists:usort([Id | lists:append([maps:get(members, W) || W <- Swarms])]),
    %% This snapshot is produced by the local runtime. Desk reachability is a
    %% separate transport observation, not evidence that this node stopped.
    #{nodes => [#{id => N, state => case N =:= Id orelse lists:member(N, Direct) orelse lists:member(N, Online) of
                    true -> <<"running">>;
                    false -> case lists:member(N, Watched) of true -> <<"down">>; false -> <<"checking">> end
                end, detail => case N of
                    Id -> <<"local_process">>;
                    _ -> case lists:member(N, Direct) of true -> <<"direct_connection">>; false -> <<"relay_connection">> end
                end} || N <- Members],
      edges => [[Id, N] || N <- Direct, lists:member(N, Members)]}.
direct_snapshot() ->
    try gen_server:call(?MODULE, snapshot, 250) of
        Snapshot -> Snapshot
    catch exit:_ -> #{nodes => [], edges => []} end.

init([]) ->
    case parvi_relay:enabled() of
        true -> ok;
        false -> ok = net_kernel:monitor_nodes(true, #{nodedown_reason => true}), self() ! poll
    end,
    {ok, #{entries => #{}, reports => #{}, pending => #{}}}.

handle_call(snapshot, _, #{entries := Entries, reports := Reports} = S) ->
    Connected = [node() | nodes()],
    Names = lists:usort(Connected ++ maps:keys(Entries)),
    Local = [{node(), N} || N <- nodes()],
    Remote = [{From, To} || {From, Peers} <- maps:to_list(Reports),
                           lists:member(From, Connected), To <- Peers, From =/= To],
    Edges = lists:usort([pair(A, B) || {A, B} <- Local ++ Remote]),
    Extra = lists:usort([N || {A, B} <- Local ++ Remote, N <- [A, B],
                            not lists:member(N, Names)]),
    Rows = [row(N, maps:get(N, Entries, {checking, pending})) || N <- Names] ++
           [row(N, {checking, reported_by_peer}) || N <- Extra],
    {reply, #{nodes => Rows, edges => [[A, B] || {A, B} <- Edges]}, S}.

handle_cast(_, S) -> {noreply, S}.

handle_info(poll, S) ->
    erlang:send_after(3000, self(), poll),
    {noreply, lists:foldl(fun probe/2, S, [node() | nodes()])};
handle_info({nodeup, Node, _}, S) ->
    {noreply, probe(Node, invalidate(Node, checking, S))};
handle_info({nodedown, Node, _}, S) ->
    {noreply, invalidate(Node, down, S)};
handle_info({probe_result, Node, Ref, Status, Peers},
            #{entries := Entries, reports := Reports, pending := Pending} = S) ->
    case maps:find(Node, Pending) of
        {ok, Ref} ->
            NextReports = case Peers of
                unavailable -> maps:remove(Node, Reports);
                _ -> Reports#{Node => Peers}
            end,
            {noreply, S#{entries := Entries#{Node => Status}, reports := NextReports,
                        pending := maps:remove(Node, Pending)}};
        _ -> {noreply, S}
    end;
handle_info(_, S) -> {noreply, S}.

probe(Node, #{pending := Pending} = S) ->
    case maps:is_key(Node, Pending) of
        true -> S;
        false ->
            Parent = self(), Ref = make_ref(),
            spawn(fun() ->
                Status = try gen_server:call({parvi_swarms, Node}, health, 1500) of
                    #{node := Node} -> {running, responsive};
                    _ -> {unresponsive, unexpected_reply}
                catch exit:{timeout, _} -> {unresponsive, timeout};
                      exit:_ -> {unresponsive, worker_unavailable} end,
                Peers = try erpc:call(Node, erlang, nodes, [], 1500) of
                    Ns when is_list(Ns), length(Ns) =< 256 -> [N || N <- Ns, is_atom(N)];
                    _ -> unavailable
                catch _:_ -> unavailable end,
                Parent ! {probe_result, Node, Ref, Status, Peers}
            end),
            S#{pending := Pending#{Node => Ref}}
    end.

invalidate(Node, State, #{entries := Entries, reports := Reports, pending := Pending} = S) ->
    S#{entries := Entries#{Node => {State, State}}, reports := maps:remove(Node, Reports),
       pending := maps:remove(Node, Pending)}.

row(Node, {State, Detail}) ->
    #{id => atom_to_binary(Node), state => atom_to_binary(State), detail => atom_to_binary(Detail)}.

pair(A, B) ->
    [First, Second] = lists:sort([atom_to_binary(A), atom_to_binary(B)]), {First, Second}.
