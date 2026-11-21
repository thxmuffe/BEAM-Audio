%% The one request/approval pipeline. The Device that would act on a request
%% decides it here, for every requester alike:
%%
%%   1. authenticate: the request carries its sender's signature and names this
%%      Device and the current Session policy (ba_session_control_protocol).
%%   2. authorize/3:  the sender's Session rights allow the operation.
%%   3. approve/2:    this Device's user consents. Always approves automatically,
%%      Ask leaves the request for the user, No refuses. Requests that only
%%      exercise a Session right the requester holds approve automatically.
%%   4. execute:      the caller acts only on an approved request.
%%
%% Each stage is evaluated per request against current state. A resource grant
%% permits future requests. An action approval consumes one pending request.
%% No process, cache or network work is introduced by this module.
-module(ba_device_request).
-export([authorize/3,approve/2,approve/3]).

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
required(<<"inspect.read">>,_) -> [capabilities_read];
required(<<"stream.message">>,#{<<"kind">> := <<"subscribe">>}) -> [stream_subscribe];
required(<<"session.request">>,#{<<"kind">> := <<"playback_step">>}) -> [stream_subscribe];
%% Session requests, answered by the Device able to execute them (a grant holder,
%% or the target of End). Anyone may ask for or give up a privilege.
%% Microphone publishers need no on_air privilege, so all members may ask a
%% grant holder to adjust timing. Only grant holders sign the shared setting.
required(<<"session.request">>,#{<<"kind">> := <<"response_request">>,<<"selection">> := _}) -> [stream_publish];
required(<<"session.request">>,#{<<"kind">> := <<"rename_request">>}) -> [stream_publish];
required(<<"session.request">>,#{<<"kind">> := Kind}) when Kind=:= <<"remove_request">>;Kind=:= <<"ended">> -> [end_session];
required(_,_) -> [].

%% Every approval uses the same serialized Device settings owner.
approve(Use,Requester) ->
    try ba_device_config:request(Use,Requester)
    catch exit:_ -> {error,consent_required} end.

approve(Use,Requester,Action) ->
    try ba_device_config:request_action(Use,Requester,Action)
    catch exit:_ -> {error,consent_required} end.
