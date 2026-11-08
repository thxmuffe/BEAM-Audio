%% Started on demand under parvi_sup; no separate application or cluster manager.
-module(parvi_audio_sup).
-behaviour(supervisor).
-export([start_link/0, ensure_started/0, start_source/1, start_session/1, sessions/0, init/1]).

start_link() -> supervisor:start_link({local, ?MODULE}, ?MODULE, []).

ensure_started() ->
    case whereis(parvi_swarm_control) of
        undefined -> {error, swarm_control_not_started};
        _ ->
            case supervisor:start_child(parvi_sup,
                    #{id => ?MODULE, start => {?MODULE, start_link, []},
                      type => supervisor, shutdown => infinity}) of
                {ok, _} -> ok;
                {error, {already_started, _}} -> ok;
                Error -> Error
            end
    end.

start_source(Offer) -> start_child(source, parvi_audio_source, [Offer]).
start_session(Args) when is_map(Args) -> start_child(subscription,parvi_audio_subscription,[Args]).

start_child(Kind, Module, Args) ->
    supervisor:start_child(?MODULE, #{id => {Kind, make_ref()},
        start => {Module, start_link, Args}, restart => temporary}).

sessions() ->
    case whereis(?MODULE) of
        undefined -> [];
        _ -> [Pid || {{subscription, _}, Pid, _, _} <- supervisor:which_children(?MODULE), is_pid(Pid)]
    end.

init([]) -> {ok, {#{strategy => rest_for_one, intensity => 5, period => 10},
    [#{id => audio_mixer,start => {parvi_audio_mixer,start_link,[]}},
     #{id => audio_receiver,start => {parvi_audio_receiver,start_link,[]}}]}}.
