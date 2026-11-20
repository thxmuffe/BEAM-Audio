%% Starts the Device runtime: the ba_core application, a non-distributed VM.
%% Launchers put ba_core and its dependencies on the code path.
-module(ba_runtime).
-export([start/0]).

start() -> application:ensure_all_started(ba_core).
