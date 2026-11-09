-module(ba_chat).
-behaviour(gen_server).
-export([start_link/0, system/3, system/4]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(GROUP, {ba_core, chat, 1}).
-define(OBSERVERS, {?GROUP, observers, node()}).
-define(MAX_BYTES, 4096).
-define(HISTORY_LIMIT, 200).

start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).
system(Event, Text, Details) when is_atom(Event), is_map(Details) ->
    system(info, Event, Text, Details).
system(Level, Event, Text, Details) when is_atom(Event), is_map(Details),
        (Level =:= trace orelse Level =:= info orelse Level =:= warning orelse Level =:= error) ->
    gen_server:call(?MODULE, {system, Level, Event, Text, Details}).

init([]) ->
    ok = net_kernel:monitor_nodes(true),
    ok = pg:join(ba_pg, ?GROUP, self()),
    logger:notice("BEAM Audio chat started on ~p", [node()]),
    Connected = maps:from_list([{N,true} || N <- nodes()]),
    {ok, #{history => queue:new(), count => 0, online => Connected, seen => Connected}}.

handle_call({send, Text}, _From, State) ->
    send_message(Text, #{}, State);
handle_call({system, Level, Event, Text, Details}, _From, State) ->
    send_message(Text, #{kind => system, level => Level, event => Event, details => Details}, State);
handle_call(history, _From, State) ->
    {reply, queue:to_list(maps:get(history, State)), State};
handle_call(status, _From, State) ->
    ChatProcesses = pg:get_members(ba_pg, ?GROUP),
    ChatNodes = lists:usort([node(Pid) || Pid <- ChatProcesses]),
    Status = case node() of nonode@nohost -> local_only; _ -> distributed end,
    {reply, #{node => node(), mode => Status, connected_nodes => nodes(),
              chat_nodes => ChatNodes, chat_process_count => length(ChatProcesses),
              subscriber_count => length(pg:get_local_members(ba_pg, ?OBSERVERS)),
              history_count => maps:get(count, State),
              history_limit => ?HISTORY_LIMIT}, State};
handle_call({subscribe, Pid}, _From, State) when is_pid(Pid), node(Pid) =:= node() ->
    case lists:member(Pid, pg:get_local_members(ba_pg, ?OBSERVERS)) of
        true -> ok;
        false -> ok = pg:join(ba_pg, ?OBSERVERS, Pid)
    end,
    {reply, ok, State};
handle_call({unsubscribe, Pid}, _From, State) when is_pid(Pid), node(Pid) =:= node() ->
    _ = pg:leave(ba_pg, ?OBSERVERS, Pid),
    {reply, ok, State};
handle_call(_Request, _From, State) -> {reply, {error, unsupported_request}, State}.

handle_cast({message, #{version := 1, id := Id, sender := Sender,
                        text := Text, sent_at_ms := Time} = Message}, State)
        when is_reference(Id), is_atom(Sender), is_binary(Text), is_integer(Time) ->
    case text(Text) of
        {ok, Text} -> {noreply, record_message(Message, State)};
        _ -> {noreply, State}
    end;
handle_cast(_Message, State) -> {noreply, State}.

handle_info({nodeup, Node}, #{online := Online,seen := Seen} = State) ->
    case not maps:is_key(Node,Online) andalso cluster_member(Node) of
        true ->
            {Event,Verb} = case maps:is_key(Node,Seen) of
                true -> {node_reconnected,<<" reconnected.">>};
                false -> {node_connected,<<" connected.">>}
            end,
            Next = local_event(Event,<<"[Cluster] ",(node_label(Node))/binary,Verb/binary>>,Node,State),
            {noreply,Next#{online := Online#{Node => true},seen := Seen#{Node => true}}};
        false -> {noreply,State}
    end;
handle_info({nodedown, Node}, #{online := Online} = State) ->
    case maps:is_key(Node,Online) of
        true ->
            Next = local_event(node_disconnected,
                <<"[Cluster] ",(node_label(Node))/binary," disconnected.">>,Node,State),
            {noreply,Next#{online := maps:remove(Node,Online)}};
        false -> {noreply,State}
    end;
handle_info(_Message, State) -> {noreply, State}.

%% Each endpoint records its own observed connection transition; broadcasting
%% both observations would duplicate notices. Permission survives a disconnect.
local_event(Event,Text,Node,State) ->
    Message = #{version => 1,id => make_ref(),sender => node(),
                text => Text,sent_at_ms => erlang:system_time(millisecond),
                kind => system,level => info,event => Event,details => #{node => Node}},
    record_message(Message,State).

cluster_member(Node) ->
    case application:get_env(ba_core,native_desk,false) of
        false -> true;
        true ->
            case ba_legacy_cluster_trust:snapshot() of
                #{<<"members">> := Members} ->
                    lists:any(fun(#{<<"node">> := Name}) -> Name =:= atom_to_binary(Node) end,
                              maps:values(Members));
                _ -> false
            end
    end.

node_label(Node) ->
    Name = hd(binary:split(atom_to_binary(Node),<<"@">>)),
    binary:part(Name,0,min(22,byte_size(Name))).

send_message(Text, Extra, State) ->
    case text(Text) of
        {ok, Binary} ->
            Message = Extra#{version => 1, id => make_ref(), sender => node(),
                             text => Binary, sent_at_ms => erlang:system_time(millisecond)},
            %% Record locally before replying. Remote delivery is best effort.
            Members = pg:get_members(ba_pg, ?GROUP),
            [gen_server:cast(Pid, {message, Message}) || Pid <- Members, Pid =/= self()],
            {reply, {ok, Message}, record_message(Message, State)};
        Error -> {reply, Error, State}
    end.

text(Text) when is_binary(Text), byte_size(Text) > 0, byte_size(Text) =< ?MAX_BYTES ->
    case unicode:characters_to_binary(Text, utf8, utf8) of
        Binary when is_binary(Binary) -> {ok, Binary};
        _ -> {error, invalid_utf8}
    end;
text(_) -> {error, expected_utf8_binary_1_to_4096_bytes}.

record_message(Message, #{history := History, count := Count} = State) ->
    ba_events:notify(chat),
    Added = queue:in(Message, History),
    {Kept, NewCount} = case Count < ?HISTORY_LIMIT of
        true -> {Added, Count + 1};
        false -> {queue:drop(Added), Count}
    end,
    [Pid ! {ba_message, Message} || Pid <- pg:get_local_members(ba_pg, ?OBSERVERS)],
    %% Do not put private message contents in logs.
    logger:info("BEAM Audio message received from ~p", [maps:get(sender, Message)]),
    State#{history := Kept, count := NewCount}.
