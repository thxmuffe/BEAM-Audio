%% Terminal/UI boundary. Keep chat state and transport in the OTP worker.
-module(parvi).
-export([start/0, start/1, send/1, history/0, status/0, subscribe/0, unsubscribe/0,
         connect/1, disconnect/1]).

start() ->
    %% Windows bundles pure-BEAM transport dependencies alongside its ebin.
    Root = filename:dirname(filename:dirname(code:which(?MODULE))),
    code:add_paths(filelib:wildcard(filename:join([Root, "relay_lib", "*", "ebin"]))),
    application:ensure_all_started(parvi).
%% Opt-in native foundation. Existing app startup keeps its compatibility path.
start(native_cluster) ->
    case whereis(parvi_sup) of
        undefined ->
            application:load(parvi),
            application:set_env(parvi, runtime_profile, native_cluster),
            start();
        _ -> {error, {already_started, parvi}}
    end.
send(Text) -> gen_server:call(parvi_chat, {send, Text}).
history() -> gen_server:call(parvi_chat, history).
status() -> gen_server:call(parvi_chat, status).
%% The caller receives {parvi_message, Message}. Resubscribe after pg scope restart.
subscribe() -> gen_server:call(parvi_chat, {subscribe, self()}).
unsubscribe() -> gen_server:call(parvi_chat, {unsubscribe, self()}).

%% Node names are developer-supplied atoms, never converted from network input.
connect(Node) when is_atom(Node), Node =/= nonode@nohost ->
    case node() of
        nonode@nohost -> {error, distribution_not_started};
        _ -> case net_adm:ping(Node) of
                 pong -> ok;
                 pang -> {error, unreachable}
             end
    end;
connect(_) -> {error, invalid_node}.

disconnect(Node) when is_atom(Node), Node =/= node() ->
    erlang:disconnect_node(Node);
disconnect(_) -> {error, invalid_node}.
