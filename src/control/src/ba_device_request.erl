%% The one request/approval pipeline. The Device that would act on a request
%% decides it here, for every requester alike (a Manager gains nothing):
%%
%%   1. authenticate: the request carries its sender's signature and names this
%%      Device and the current Session policy (ba_buffee_control_protocol).
%%   2. authorize/3:  the sender's Session rights allow the operation.
%%   3. approve/2:    this Device's user consents. Always approves automatically,
%%      Ask leaves the request for the user, No refuses. Requests that only
%%      exercise a Session right the requester holds approve automatically.
%%   4. execute:      the caller acts only on an approved request.
%%
%% Each stage is evaluated per request against current state; no decision is
%% remembered. A request waiting in Requests is not executed later: once the
%% user allows the use, the requester's retry is a new request, checked again.
%% No process, cache or network work is introduced by this module.
-module(ba_device_request).
-export([authorize/3,approve/2]).

%% Rights are the requester's Session permissions from installed policy.
authorize(Op,Payload,Permissions) ->
    case required(Op,Payload) of
        [] -> ok;
        Any -> case lists:any(fun(P) -> lists:member(P,Permissions) end,Any) of
            true -> ok;
            false -> {error,forbidden}
        end
    end.

%% Any one listed right suffices; [] means every Session member may ask.
required(<<"status.read">>,_) -> [status_read];
required(<<"capabilities.read">>,_) -> [capabilities_read];
required(<<"stream.message">>,#{<<"kind">> := <<"catalog.read">>}) -> [stream_read];
required(<<"stream.message">>,#{<<"kind">> := <<"subscribe">>}) -> [stream_subscribe];
%% Changing the shared offset is a Session setting: grant or on_air holders.
required(<<"time.message">>,#{<<"kind">> := <<"offset.set">>}) -> [owner,stream_publish];
required(<<"time.message">>,#{<<"kind">> := Kind}) ->
    case ba_buffee_time_protocol:permission(Kind) of none -> [];P -> [P] end;
%% Session requests, answered by the Device able to execute them (a grant holder,
%% or the target of End). Anyone may ask for or give up a privilege.
required(<<"session.request">>,#{<<"kind">> := <<"rename_request">>}) -> [stream_publish];
required(<<"session.request">>,#{<<"kind">> := Kind}) when Kind=:= <<"remove_request">>;Kind=:= <<"ended">> -> [end_session];
required(_,_) -> [].

%% Requests for Session rights follow this Device's user's answer for them.
%% Pending requests are kept by the component that would execute them.
approve(Answer,_) when Answer=:=on_air_requests;Answer=:=moderator_requests ->
    case try ba_device_config:policy(Answer) catch exit:_ -> ask end of
        always -> ok;
        ask -> {error,waiting_for_approval};
        no -> {error,refused}
    end;
%% Consent is a protected local use (ba_device_config). Never blocks on the user.
approve(Use,Requester) ->
    case ba_device_permission:allowed(Use) of
        true -> ok;
        false ->
            try ba_device_config:request(Use,Requester) of
                ok -> ok;
                {error,_}=Refused -> Refused
            catch exit:_ -> {error,consent_required} end
    end.
