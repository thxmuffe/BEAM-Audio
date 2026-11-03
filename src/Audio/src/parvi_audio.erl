%% Shared control API. Descriptors/configuration are Erlang terms, not a wire format.
-module(parvi_audio).
-export([publish/1, publish/2, unpublish/1, sources/0, describe/1, watch_sources/0,
         subscribe/2, ready/1, close/1, status/1, sessions/0, push/4, listen/2,
         validate_offer/1, validate_request/2, handler/0, backend/0]).
-define(SOURCES, {parvi, audio, sources}).

publish(Offer) -> publish(Offer, undefined).
%% A capture worker can explicitly own a publication; ordinary offers stay runtime-owned.
publish(Offer, Owner) when Owner =:= undefined; is_pid(Owner), node(Owner) =:= node() ->
    case validate_offer(Offer) of
        ok -> with_runtime(fun() -> parvi_audio_sup:start_source({Offer, Owner}) end);
        Error -> Error
    end.
unpublish(Source) -> gen_server:stop(Source).
sources() -> pg:get_members(parvi_pg, ?SOURCES).
describe(Source) -> gen_server:call(Source, describe).
%% The caller owns the monitor. pg:demonitor(parvi_pg, Ref) stops notifications.
watch_sources() -> pg:monitor(parvi_pg, ?SOURCES).
sessions() -> parvi_audio_sup:sessions().
%% Diagnostic only: this does not start audio or select an unbundled engine.
handler() -> Handler = parvi_audio_stream_handler:default(), Handler:info().
%% Compatibility diagnostic name used by existing Apple snapshots.
backend() -> handler().
status(Session) -> gen_statem:call(Session, status).
%% Call from the local capture/runtime worker; samples never traverse OTP control.
push(Source, Profile, Header, PCM) when node(Source) =:= node() ->
    gen_server:call(Source, {push, Profile, Header, PCM}).
listen(Session, Consumer) when node(Session) =:= node() ->
    gen_statem:call(Session, {listen, Consumer}).

subscribe(Source, #{profile := Profile} = Request) when is_pid(Source) ->
    with_runtime(fun() ->
        #{profiles := Profiles} = describe(Source),
        case maps:find(Profile,Profiles) of
            {ok,D} ->
                Handler = parvi_audio_stream_handler:for_descriptor(D),
                case parvi_audio_sup:start_session({receiver,self(),Handler}) of
                    {ok,Pid} -> session_call(Pid,{open,Source,Request});
                    Error -> Error
                end;
            error -> {error,unsupported_profile}
        end
    end);
subscribe(_, _) -> {error, invalid_request}.

ready(Session) when is_pid(Session), node(Session) =:= node() -> session_call(Session, ready).
close(Session) when is_pid(Session), node(Session) =:= node() -> gen_statem:stop(Session).

with_runtime(Fun) ->
    case parvi_audio_sup:ensure_started() of ok -> Fun(); Error -> Error end.

session_call(Pid, Request) ->
    try gen_statem:call(Pid, Request, 6000)
    catch exit:Reason ->
        %% A local call timeout must not leave a half-open remote subscription.
        exit(Pid, shutdown), {error, {session_unavailable, Reason}}
    end.

validate_offer(#{name := Name, profiles := Profiles})
        when is_binary(Name), byte_size(Name) > 0, is_map(Profiles), map_size(Profiles) > 0 ->
    case lists:all(fun({Profile, Descriptor}) ->
        Handler = parvi_audio_stream_handler:for_descriptor(Descriptor),
        lists:member(Profile, [channel, point]) andalso
            Handler:validate_descriptor(Profile, Descriptor) =:= ok
    end, maps:to_list(Profiles)) of
        true -> ok;
        false -> {error, invalid_offer}
    end;
validate_offer(_) -> {error, invalid_offer}.

validate_request(#{profile := Profile, selector := Selector}, #{profiles := Profiles}) ->
    case maps:find(Profile, Profiles) of
        error -> {error, unsupported_profile};
        {ok, Descriptor} ->
            case valid_selector(Profile, Selector) of
                true -> {ok, Descriptor};
                false -> {error, invalid_selector}
            end
    end;
validate_request(_, _) -> {error, invalid_request}.

valid_selector(_, all) -> true;
valid_selector(channel, #{channels := Channels}) when is_list(Channels), Channels =/= [] ->
    lists:all(fun(C) -> is_integer(C) andalso C >= 0 end, Channels);
valid_selector(point, #{x := X, y := Y, z := Z, radius := R}) ->
    is_number(X) andalso is_number(Y) andalso is_number(Z) andalso is_number(R) andalso R >= 0;
valid_selector(_, _) -> false.
