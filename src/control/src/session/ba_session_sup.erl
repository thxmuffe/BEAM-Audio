%% Each additional Session owns its local state and supervision tree.
-module(ba_session_sup).
-behaviour(supervisor).
-export([start_link/1,init/1]).
start_link(Id) -> supervisor:start_link({global,{ba_session,Id,ba_sup}},?MODULE,[Id]).
init([Id]) ->
    ba_session_scope:clear(Id),ba_session_scope:enter(Id),ba_session_scope:set_env(restore_session_on_start,true),
    {ok,{#{strategy => one_for_one,intensity => 5,period => 10},[
        #{id => ba_session_desks,start => {ba_session_desks,start_link,[]}},
        #{id => ba_session,start => {ba_session,start_link,[]}}
    ]}}.
