%% Windows capture adapter for the shared audio Worker (ba_device_audio).
%% Microphone and system capture are not connected to the shared pipeline yet;
%% say so explicitly instead of appearing idle. Playback (ba_windows_output)
%% does not depend on this module.
-module(ba_windows_input).
-export([start/1,stop/1,status/1]).
start(K) when K=:=microphone;K=:=broadcast -> {error,<<"Capture is not available on Windows yet.">>}.
stop(_) -> ok.
status(_) -> #{state => stopped}.
