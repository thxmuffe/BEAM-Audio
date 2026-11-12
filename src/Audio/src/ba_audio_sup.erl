%% On demand after the clock in the dependency-ordered runtime branch.
-module(ba_audio_sup).
-behaviour(supervisor).
-export([start_link/0, ensure_started/0, start_source/1, start_session/1, sessions/0, init/1]).

start_link() -> supervisor:start_link(ba_session_scope:registration(?MODULE), ?MODULE, []).

ensure_started() ->
    case ba_session_scope:whereis(ba_buffee_control) of
        undefined -> {error, buffee_control_not_started};
        _ ->
            case supervisor:start_child(ba_session_scope:ref(ba_buffee_runtime_sup),
                    #{id => ?MODULE, start => {?MODULE, start_link, []},
                      type => supervisor, shutdown => infinity}) of
                {ok, _} -> ok;
                {error, {already_started, _}} -> ok;
                Error -> Error
            end
    end.

start_source(Offer) -> start_child(source, ba_audio_source, [Offer]).
start_session(Args) when is_map(Args) -> start_child(subscription,ba_media_session,[Args]).

start_child(Kind, Module, Args) ->
    supervisor:start_child(ba_session_scope:ref(?MODULE), #{id => {Kind, make_ref()},
        start => {Module, start_link, Args}, restart => temporary}).

sessions() ->
    case ba_session_scope:whereis(?MODULE) of
        undefined -> [];
        _ -> [Pid || {{subscription, _}, Pid, _, _} <- supervisor:which_children(ba_session_scope:ref(?MODULE)), is_pid(Pid)]
    end.

init([]) -> {ok, {#{strategy => rest_for_one, intensity => 5, period => 10},
    [#{id => audio_mixer,start => {ba_audio_mixer,start_link,[]}},
     #{id => audio_receiver,start => {ba_audio_receiver,start_link,[]}}]}}.
