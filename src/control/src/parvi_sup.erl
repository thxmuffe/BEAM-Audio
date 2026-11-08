-module(parvi_sup).
-behaviour(supervisor).
-export([start_link/0, init/1]).

start_link() -> supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    case application:get_env(parvi,runtime_profile,legacy_apps) of
        swarm_control ->
            {ok,{#{strategy => one_for_one,intensity => 5,period => 10},
                 [#{id => parvi_device_sup,start => {parvi_device_sup,start_link,[]},
                    type => supervisor,shutdown => infinity},
                  #{id => parvi_swarm_control,start => {parvi_swarm_control,start_link,[]}}]}};
        _ -> existing_profile()
    end.

existing_profile() ->
    %% Restart chat too if its process-group scope disappears.
    Core = [
        #{id => parvi_pg, start => {pg, start_link, [parvi_pg]}},
        #{id => parvi_chat, start => {parvi_chat, start_link, []}}
    ],
    Compatibility = [
        #{id => parvi_discovery, start => {parvi_discovery, start_link, []}},
        #{id => parvi_relay, start => {parvi_relay, start_link, []}},
        #{id => parvi_direct, start => {parvi_direct, start_link, []}},
        #{id => parvi_network, start => {parvi_network, start_link, []}},
        #{id => parvi_swarms, start => {parvi_swarms, start_link, []}}
    ],
    Children = case application:get_env(parvi, runtime_profile, legacy_apps) of
        native_cluster -> Core ++ case application:get_env(parvi, native_desk, false) of
            true -> [#{id => parvi_cluster_desk, start => {parvi_cluster_desk, start_link, []}}];
            false -> []
        end;
        legacy_apps -> Core ++ Compatibility
    end,
    Clock = #{id => parvi_clock_sup, start => {parvi_clock_sup, start_link, []},
              type => supervisor, shutdown => infinity},
    {ok, {#{strategy => rest_for_one, intensity => 5, period => 10}, Children ++ [Clock]}}.
