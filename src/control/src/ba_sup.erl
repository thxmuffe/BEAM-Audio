-module(ba_sup).
-behaviour(supervisor).
-export([start_link/0, init/1]).

start_link() -> supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    ok=ba_session_scope:init(),
    {ok,{#{strategy => one_for_one,intensity => 5,period => 10},
         [#{id => ba_settings,start => {ba_settings,start_link,[]}},
          #{id => ba_permission_pg,start => {pg,start_link,[ba_permission_pg]}},
          #{id => ba_device_config,start => {ba_device_config,start_link,[]}},
          #{id => ba_contacts,start => {ba_contacts,start_link,[]}},
          #{id => ba_desk_connections_sup,start => {ba_desk_connections_sup,start_link,[]},type => supervisor,shutdown => infinity},
          #{id => ba_session_desks,start => {ba_session_desks,start_link,[]}},
          #{id => ba_session,start => {ba_session,start_link,[]}},
          #{id => ba_sessions,start => {ba_sessions,start_link,[]}}]}}.
