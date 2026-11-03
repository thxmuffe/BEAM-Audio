%% Capability-addressed relay. No swarms or chat histories live here.
-module(parvi_reception_sessions).
-behaviour(gen_server).
-export([start_link/0, attach/2, command/3]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).
start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).
attach(Id, Pid) -> gen_server:call(?MODULE, {attach, Id, Pid}).
command(Id, Pid, Message) -> gen_server:call(?MODULE, {command, Id, Pid, Message}).
init([]) -> erlang:send_after(30000, self(), sweep), {ok, #{}}.
handle_call({attach, Id, Pid}, _, S) when map_size(S) < 4096; is_map_key(Id, S) ->
    Old = maps:get(Id, S, #{boxes => #{}, watch => []}),
    case maps:get(pid, Old, undefined) of P when is_pid(P), P =/= Pid -> P ! replaced; _ -> ok end,
    monitor(process, Pid),
    Next = S#{Id => Old#{pid => Pid, seen => now_ms()}},
    presence(Next), {reply, ok, Next};
handle_call({attach, _, _}, _, S) -> {reply, {error, full}, S};
handle_call({command, Id, Pid, Msg}, _, S) ->
    case maps:find(Id, S) of
        {ok, #{pid := Pid} = Entry} ->
            {Reply, Next} = route(Id, Entry, Msg, S), {reply, Reply, Next};
        _ -> {reply, {error, unauthenticated}, S}
    end;
handle_call(_, _, S) -> {reply, {error, invalid}, S}.
handle_cast(_, S) -> {noreply, S}.
handle_info({'DOWN', _, process, Pid, _}, S) ->
    Next = maps:map(fun(_, E) -> case maps:get(pid, E) of
        Pid -> E#{pid := undefined, seen := now_ms()}; _ -> E end end, S),
    presence(Next), {noreply, Next};
handle_info(sweep, S) ->
    erlang:send_after(30000, self(), sweep),
    {noreply, maps:filter(fun(_, E) -> is_pid(maps:get(pid, E)) orelse now_ms() - maps:get(seen, E) < 300000 end, S)};
handle_info(_, S) -> {noreply, S}.

route(Id, #{boxes := Boxes} = E, #{<<"op">> := <<"open">>, <<"mailbox">> := Cap, <<"swarm">> := Swarm}, S)
        when map_size(Boxes) < 64; is_map_key(Cap, Boxes) ->
    case hex(Cap, 32) andalso hex(Swarm, 32) of
        true -> {ok, S#{Id := E#{boxes := Boxes#{Cap => Swarm}}}};
        false -> {{error, invalid_mailbox}, S}
    end;
route(Id, #{boxes := Boxes} = E, #{<<"op">> := <<"close">>, <<"mailbox">> := Cap}, S) ->
    {ok, S#{Id := E#{boxes := maps:remove(Cap, Boxes)}}};
route(Id, E, #{<<"op">> := <<"watch">>, <<"nodes">> := Nodes}, S) when is_list(Nodes), length(Nodes) =< 256 ->
    case lists:all(fun(N) -> hex(N, 64) end, Nodes) of
        true -> Next = S#{Id := E#{watch := lists:usort(Nodes)}}, notify(Id, Next), {ok, Next};
        false -> {{error, invalid_nodes}, S}
    end;
route(From, _, #{<<"op">> := <<"send">>, <<"to">> := To, <<"mailbox">> := Cap,
                <<"payload">> := #{<<"swarm">> := Swarm} = Payload} = Msg, S) ->
    case maps:find(To, S) of
        {ok, #{pid := Pid, boxes := Boxes}} when is_pid(Pid) ->
            case maps:find(Cap, Boxes) of
                {ok, Swarm} ->
                    case process_info(Pid, message_queue_len) of
                        {message_queue_len, N} when N < 256 ->
                            Pid ! {relay, #{op => <<"delivery">>, from => From, mailbox => Cap, payload => Payload}}, {ok, S};
                        _ -> {{error, overloaded}, S}
                    end;
                _ -> {{error, unavailable}, S}
            end;
        _ ->
            %% Same response for unknown/offline destinations; no public directory.
            _ = Msg, {{error, unavailable}, S}
    end;
route(_, _, _, S) -> {{error, invalid_message}, S}.
presence(S) -> [notify(Id, S) || Id <- maps:keys(S)], ok.
notify(Id, S) ->
    #{pid := Pid, watch := Watch} = maps:get(Id, S),
    case is_pid(Pid) of
        true -> Pid ! {relay, #{op => <<"presence">>, online => [N || N <- Watch, connected(N, S)]}};
        false -> ok
    end.
connected(Id, S) -> case maps:find(Id, S) of {ok, #{pid := P}} -> is_pid(P); _ -> false end.
hex(B, Size) when is_binary(B), byte_size(B) =:= Size ->
    re:run(B, <<"^[0-9A-F]+$">>, [{capture, none}]) =:= match;
hex(_, _) -> false.
now_ms() -> erlang:monotonic_time(millisecond).
