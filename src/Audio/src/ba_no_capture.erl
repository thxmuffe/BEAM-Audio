%% Capture adapter for platforms without native capture yet. Audio is native
%% AAC only (owner decision 2026-11-19); nothing is captured through Erlang.
-module(ba_no_capture).
-export([start/1,stop/1,status/1,unavailable/0]).
-define(TEXT,<<"Sending sound from this Device is not available yet.">>).
start(_) -> {error,native_capture_unavailable}.
stop(_) -> ok.
status(_) -> #{state => unsupported,error => ?TEXT}.
unavailable() -> #{<<"microphone">> => ?TEXT,<<"broadcast">> => ?TEXT}.
