%% Test helper: this Device's consent granted the one real way, a running
%% permission registry and Device configuration owner (no state dir).
-module(ba_test_consent).
-export([with/2,start/1,stop/1]).

with(Consent,Fun) ->
    State=start(Consent),
    try Fun() after stop(State) end.

start(Consent) ->
    Dir=os:getenv("BA_STATE_DIR"),os:unsetenv("BA_STATE_DIR"),
    {ok,PG}=pg:start_link(ba_permission_pg),unlink(PG),
    {ok,Config}=ba_device_config:start_link(),unlink(Config),
    ok=ba_device_config:change(Consent,#{}),
    {Dir,[Config,PG]}.

stop({Dir,Pids}) ->
    [begin Ref=monitor(process,P),exit(P,kill),receive {'DOWN',Ref,_,_,_} -> ok end end || P <- Pids],
    case Dir of false -> ok;_ -> os:putenv("BA_STATE_DIR",Dir) end,
    ok.
