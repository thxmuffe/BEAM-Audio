%% Node names are opaque binaries here. Never create atoms from HTTP input.
-module(parvi_directory).
-behaviour(gen_server).
-export([start_link/0, register/1, nodes/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).
register(Node) -> gen_server:call(?MODULE, {register, Node}).
nodes() -> gen_server:call(?MODULE, nodes).
init([]) -> {ok, []}.

handle_call(nodes, _From, Nodes) -> {reply, Nodes, Nodes};
handle_call({register, Node}, _From, Nodes) ->
    case valid(Node) of
        false -> {reply, {error, invalid_node_id}, Nodes};
        true ->
            case {ordsets:is_element(Node, Nodes), length(Nodes) < 256} of
                {true, _} -> {reply, {ok, Nodes}, Nodes};
                {false, true} ->
                    Updated = ordsets:add_element(Node, Nodes),
                    {reply, {ok, Updated}, Updated};
                {false, false} -> {reply, {error, directory_full}, Nodes}
            end
    end;
handle_call(_, _From, Nodes) -> {reply, {error, unsupported_request}, Nodes}.
handle_cast(_, Nodes) -> {noreply, Nodes}.
handle_info(_, Nodes) -> {noreply, Nodes}.

valid(Node) when is_binary(Node), byte_size(Node) > 2, byte_size(Node) =< 255 ->
    re:run(Node, <<"^[A-Za-z0-9_][A-Za-z0-9_.-]*@[A-Za-z0-9][A-Za-z0-9.:-]*$">>,
           [{capture, none}]) =:= match;
valid(_) -> false.
