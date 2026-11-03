%% Shared discovery client. The current prototype permits loopback HTTP only.
-module(parvi_discovery).
-behaviour(gen_server).
-export([start_link/0, discover/1, nodes/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).
start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).
discover(URL) -> gen_server:call(?MODULE, {discover, URL}, 5000).
nodes() -> gen_server:call(?MODULE, nodes).
init([]) -> {ok, []}.
handle_call(nodes, _From, Nodes) -> {reply, Nodes, Nodes};
handle_call({discover, URL}, _From, Nodes) ->
    case fetch(URL) of
        {ok, Discovered} -> {reply, ok, Discovered};
        {error, Error} -> {reply, {error, Error}, Nodes}
    end;
handle_call(_, _From, Nodes) -> {reply, {error, <<"Unsupported discovery request">>}, Nodes}.
handle_cast(_, Nodes) -> {noreply, Nodes}.
handle_info(_, Nodes) -> {noreply, Nodes}.

fetch(URL) when is_binary(URL), byte_size(URL) =< 256 ->
    try
        #{scheme := <<"http">>, host := Host} = Parsed = uri_string:parse(URL),
        true = lists:member(Host, [<<"127.0.0.1">>, <<"localhost">>]),
        false = maps:is_key(userinfo, Parsed),
        false = maps:is_key(query, Parsed),
        false = maps:is_key(fragment, Parsed),
        true = lists:member(maps:get(path, Parsed, <<>>), [<<>>, <<"/">>]),
        Endpoint = binary_to_list(iolist_to_binary([string:trim(URL, trailing, "/"), "/api/nodes"])),
        Body = iolist_to_binary(json:encode(#{node_id => atom_to_binary(node())})),
        case httpc:request(post, {Endpoint, [], "application/json", Body},
                           %% Only plaintext loopback HTTP is accepted above. Avoid
                           %% initializing unused TLS defaults in the minimal bundle.
                           [{timeout, 2500}, {connect_timeout, 1500},
                            {autoredirect, false}, {ssl, []}],
                           [{body_format, binary}]) of
            {ok, {{_, 200, _}, _, Reply}} when byte_size(Reply) =< 131072 ->
                #{<<"node_ids">> := IDs} = json:decode(Reply),
                true = is_list(IDs) andalso length(IDs) =< 256,
                true = lists:all(fun valid/1, IDs),
                {ok, lists:usort([ID || ID <- IDs, ID =/= atom_to_binary(node())])};
            _ -> {error, <<"Reception desk unavailable. Start src/Services/ReceptionDesk/run.sh and check its URL.">>}
        end
    catch
        _:_ -> {error, <<"Use a local reception desk URL such as http://127.0.0.1:8765. Invalid directory replies are rejected.">>}
    end;
fetch(_) -> {error, <<"Invalid broker URL">>}.

valid(ID) when is_binary(ID), byte_size(ID) =< 255 ->
    re:run(ID, <<"^[A-Za-z0-9_][A-Za-z0-9_.-]*@[A-Za-z0-9][A-Za-z0-9.:-]*$">>, [{capture, none}]) =:= match;
valid(_) -> false.
