%% Dependency ordering inside the runtime, separate from Desk connection failures.
-module(ba_buffee_runtime_sup).
-behaviour(supervisor).
-export([start_link/0,init/1]).
start_link() -> supervisor:start_link(ba_session_scope:registration(?MODULE),?MODULE,[]).
init([]) ->
    ba_session_scope:new_table(ba_buffee_state,[named_table,public,set]),
    {ok,{#{strategy => rest_for_one,intensity => 5,period => 10,auto_shutdown => any_significant},
         [#{id => ba_buffee_membership,start => {ba_buffee_membership,start_link,[]},restart => temporary,significant => true},
          #{id => ba_device_sup,start => {ba_device_sup,start_link,[]},type => supervisor,shutdown => infinity},
          #{id => ba_buffee_control,start => {ba_buffee_control,start_link,[]}},
          #{id => ba_buffee_chat,start => {ba_buffee_chat,start_link,[]}},
          #{id => ba_buffee_clock_sup,start => {ba_buffee_clock_sup,start_link,[]},type => supervisor,shutdown => infinity}]}}.
