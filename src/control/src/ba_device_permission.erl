%% Execution checks, not a boundary against compromised local BEAM code.
-module(ba_device_permission).
-export([allowed/1,enter/1,valid/2,revoke/1,revoke/2]).
allowed(broadcast) ->
    case application:get_env(ba_core,runtime_profile,legacy_apps) of
        buffee_control ->
            try ba_buffee:broadcast() andalso lists:member(chef,maps:get(roles,ba_buffee_membership:status(),[]))
            catch exit:_ -> false end;
        _ -> true
    end;
allowed(playback) -> ba_device_config:allowed(speaker);
allowed(record) -> ba_device_config:allowed(microphone);
allowed(microphone) -> allowed(record);
allowed(calibrate) -> ba_device_config:allowed(calibrate);
allowed(dsp) -> ba_device_config:allowed(dsp);
allowed(legacy_capture) -> application:get_env(ba_core,runtime_profile,legacy_apps)=/=buffee_control;
allowed(_) -> false.

key(playback) -> speaker;
key(record) -> microphone;
key(microphone) -> microphone;
key(K) -> K.
enter(broadcast) ->
    case application:get_env(ba_core,runtime_profile,legacy_apps) of
        buffee_control -> case allowed(broadcast) of true -> ba_buffee:broadcast_token();false -> {error,consent_required} end;
        _ -> {ok,legacy}
    end;
enter(Operation) ->
    case application:get_env(ba_core,runtime_profile,legacy_apps) of
        buffee_control ->
            try
                Registry=whereis(ba_permission_pg),Group=key(Operation),
                case get({permission_registry,Group})=:=Registry andalso Registry=/=undefined of
                    true -> ok;false -> pg:join(ba_permission_pg,Group,self()),put({permission_registry,Group},Registry)
                end,
                ba_device_config:token(Group)
            catch exit:_ -> {error,permission_registry_unavailable} end;
        _ -> {ok,legacy}
    end.
valid(broadcast,legacy) -> application:get_env(ba_core,runtime_profile,legacy_apps)=/=buffee_control;
valid(broadcast,Token) -> try allowed(broadcast) andalso ba_buffee:broadcast_token()=:={ok,Token} catch exit:_ -> false end;
valid(Operation,Token) -> ba_device_config:token(key(Operation))=:={ok,Token}.
revoke(Keys) -> revoke(Keys,[]).
revoke(Keys,Previous) ->
    case application:get_env(ba_core,runtime_profile,legacy_apps) of
        buffee_control ->
            try
                Pids=lists:usort(Previous++lists:append([pg:get_local_members(ba_permission_pg,K) || K <- Keys])),
                Requests=[{P,gen_server:send_request(P,{revoke_permissions,Keys})} || P <- Pids],
                Deadline=erlang:monotonic_time(millisecond)+4000,
                Results=[{P,gen_server:wait_response(R,max(0,Deadline-erlang:monotonic_time(millisecond)))} || {P,R} <- Requests],
                case [P || {P,R} <- Results,R=/={reply,ok}] of [] -> ok;Failed -> {error,Failed} end
            catch _:_ -> {error,Previous} end;
        _ -> ok
    end.
