%% Lifecycle wrapper around OTP's HTTP server, not a custom HTTP parser.
-module(parvi_broker_http).
-behaviour(gen_server).
-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).
init([]) ->
    Root = filename:dirname(code:which(?MODULE)),
    {ok, Address} = application:get_env(parvi_broker, bind_address),
    {ok, Port} = application:get_env(parvi_broker, port),
    Config = [{port, Port}, {bind_address, Address}, {server_name, "parvi-local"},
              {server_root, Root}, {document_root, Root},
              {modules, [parvi_broker_routes]}, {max_clients, 32},
              {max_header_size, 8192}, {max_body_size, 1024}, {keep_alive_timeout, 5}],
    case inets:start(httpd, Config) of
        {ok, Pid} ->
            monitor(process, Pid),
            logger:notice("Parvi directory listening at http://~s:~B", [inet:ntoa(Address), Port]),
            {ok, Pid};
        {error, Reason} -> {stop, Reason}
    end.
handle_call(_, _From, Pid) -> {reply, ok, Pid}.
handle_cast(_, Pid) -> {noreply, Pid}.
handle_info({'DOWN', _, process, Pid, Reason}, Pid) -> {stop, {httpd_down, Reason}, Pid};
handle_info(_, Pid) -> {noreply, Pid}.
terminate(_, Pid) -> inets:stop(httpd, Pid), ok.
