-module(ba_sup).
-behaviour(supervisor).
-export([start_link/0, init/1]).

start_link() -> supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    case application:get_env(ba_core,runtime_profile,legacy_apps) of
        swarm_control ->
            {ok,{#{strategy => one_for_one,intensity => 5,period => 10},
                 [#{id => ba_contacts,start => {ba_contacts,start_link,[]}},
                  #{id => ba_desk_connections_sup,start => {ba_desk_connections_sup,start_link,[]},type => supervisor,shutdown => infinity},
                  #{id => ba_swarm_desks,start => {ba_swarm_desks,start_link,[]}},
                  #{id => ba_swarm,start => {ba_swarm,start_link,[]}}]}};
        _ -> existing_profile()
    end.

existing_profile() ->
    %% Restart chat too if its process-group scope disappears.
    Core = [
        #{id => ba_pg, start => {pg, start_link, [ba_pg]}},
        #{id => ba_chat, start => {ba_chat, start_link, []}}
    ],
    Compatibility = [
        #{id => ba_discovery, start => {ba_discovery, start_link, []}},
        #{id => ba_relay, start => {ba_relay, start_link, []}},
        #{id => ba_direct, start => {ba_direct, start_link, []}},
        #{id => ba_network, start => {ba_network, start_link, []}},
        #{id => ba_swarms, start => {ba_swarms, start_link, []}}
    ],
    Children = case application:get_env(ba_core, runtime_profile, legacy_apps) of
        native_cluster -> Core ++ case application:get_env(ba_core, native_desk, false) of
            true -> [#{id => ba_legacy_cluster_desk, start => {ba_legacy_cluster_desk, start_link, []}}];
            false -> []
        end;
        legacy_apps -> Core ++ Compatibility
    end,
    Clock = #{id => ba_swarm_clock_sup, start => {ba_swarm_clock_sup, start_link, []},
              type => supervisor, shutdown => infinity},
    {ok, {#{strategy => rest_for_one, intensity => 5, period => 10}, Children ++ [Clock]}}.
