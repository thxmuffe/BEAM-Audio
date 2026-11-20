%% Dependency ordering inside the runtime, separate from Desk connection failures.
-module(ba_session_runtime_sup).
-behaviour(supervisor).
-export([start_link/0,init/1]).
start_link() -> supervisor:start_link(ba_session_scope:registration(?MODULE),?MODULE,[]).
init([]) ->
    ba_session_scope:new_table(ba_session_state,[named_table,public,set]),
    {ok,{#{strategy => rest_for_one,intensity => 5,period => 10,auto_shutdown => any_significant},
         [#{id => ba_session_membership,start => {ba_session_membership,start_link,[]},restart => temporary,significant => true},
          #{id => ba_device_sup,start => {ba_device_sup,start_link,[]},type => supervisor,shutdown => infinity},
          #{id => ba_session_control,start => {ba_session_control,start_link,[]}},
          #{id => ba_session_chat,start => {ba_session_chat,start_link,[]}},
          #{id => ba_response_time,start => {ba_response_time,start_link,[]}},
          #{id => ba_session_clock_sup,start => {ba_session_clock_sup,start_link,[]},type => supervisor,shutdown => infinity}]}}.
