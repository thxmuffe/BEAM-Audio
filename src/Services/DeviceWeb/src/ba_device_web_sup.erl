%% Optional OTP application, usable inside a Device or as a local socket client.
-module(ba_device_web_sup).
-behaviour(supervisor).
-export([start_link/1,init/1,origin/0,token/0]).

start_link(Options) -> supervisor:start_link({local,?MODULE},?MODULE,Options).

origin() ->
    iolist_to_binary(["http://127.0.0.1:",integer_to_list(ranch:get_port(ba_device_web))]).

token() ->
    [{token,Token}]=ets:lookup(ba_device_web_session,token),Token.

init(Options) ->
    Mode=maps:get(mode,Options,device),
    true=lists:member(Mode,[device,preview]),
    Token=binary:encode_hex(crypto:strong_rand_bytes(32)),
    %% Keep credentials out of listener specifications and supervisor reports.
    ets:new(ba_device_web_session,[named_table,protected,{read_concurrency,true}]),
    ets:insert(ba_device_web_session,{token,Token}),
    State=Options#{mode => Mode},
    Dispatch=cowboy_router:compile([{'_',[{"/[...]",ba_device_web_handler,State}]}]),
    %% Embed Ranch's listener in this application's supervision tree. Closing or
    %% restarting the app therefore also closes/restarts its connections.
    Listener=ranch:child_spec(ba_device_web,ranch_tcp,
        #{socket_opts => [{ip,{127,0,0,1}},{port,maps:get(port,Options,8766)}],
          connection_type => supervisor,num_acceptors => 4,max_connections => 64},
        cowboy_clear,#{connection_type => supervisor,env => #{dispatch => Dispatch},
                       idle_timeout => 25000,request_timeout => 25000}),
    {ok,{#{strategy => one_for_one,intensity => 5,period => 10},[Listener]}}.
