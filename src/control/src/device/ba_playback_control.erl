%% One-shot, addressed controls for a Device's own system-audio publication.
-module(ba_playback_control).
-behaviour(gen_server).
-export([start_link/0,request/3,receive_request/2,answer/2,validate/1]).
-export([init/1,handle_call/3,handle_cast/2,handle_info/2]).

start_link() -> gen_server:start_link(ba_session_scope:registration(?MODULE),?MODULE,[],[]).

request(Peer,Direction,Incarnation) ->
    Payload=#{<<"kind">> => <<"playback_step">>,<<"direction">> => Direction,<<"incarnation">> => Incarnation},
    ok=validate(Payload),true=ba_hex:valid(Peer,64),
    ba_session_control:send_session_request(Peer,Payload).

receive_request(Payload,Context) ->
    case ba_session_scope:whereis(?MODULE) of
        undefined -> ok;
        Pid ->
            case process_info(Pid,message_queue_len) of
                {message_queue_len,N} when N<16 -> gen_server:cast(Pid,{remote,Payload,Context});
                _ -> ok
            end
    end.

answer(Id,Allow) ->
    case ba_device_config:answer_action(playback_control,Id) of
        {ok,#{scope := Scope}=Action} ->
            ba_session_scope:run(Scope,fun() ->
                case ba_session_scope:whereis(?MODULE) of
                    undefined -> {error,request_expired};
                    Pid -> gen_server:cast(Pid,{answer,Allow,Action})
                end
            end);
        Error -> Error
    end.

validate(#{<<"kind">> := <<"playback_step">>,<<"direction">> := Direction,<<"incarnation">> := Inc}=P) ->
    ba_session_passport:exact(P,[<<"kind">>,<<"direction">>,<<"incarnation">>]),
    true=lists:member(Direction,[<<"previous">>,<<"next">>]),
    true=ba_hex:valid(Inc,32),ok;
validate(#{<<"kind">> := <<"playback_result">>,<<"status">> := Status}=P) ->
    true=lists:member(Status,[<<"done">>,<<"waiting_for_approval">>,<<"declined">>,<<"refused">>,
        <<"busy">>,<<"unavailable">>,<<"unsupported">>,<<"no_playable_track">>,<<"automation_denied">>]),
    case maps:find(<<"track">>,P) of
        {ok,Track} ->
            <<"done">>=Status,true=track_text(Track),
            ba_session_passport:exact(P,[<<"kind">>,<<"status">>,<<"track">>]);
        error -> ba_session_passport:exact(P,[<<"kind">>,<<"status">>])
    end,ok.

init([]) -> {ok,#{}}.
handle_call(_,_,S) -> {reply,{error,unsupported},S}.
handle_cast({remote,#{<<"kind">> := <<"playback_step">>,<<"direction">> := Direction,
        <<"incarnation">> := Inc},#{peer := Peer,deadline := Until}=Context},S) ->
    Id=binary:encode_hex(crypto:strong_rand_bytes(16)),
    Action=#{id => Id,from => Peer,scope => ba_session_scope:current(),direction => Direction,incarnation => Inc,
             context => Context,deadline => min(Until,now_ms()+30000)},
    Next=case {os:type(),eligible(Action)} of
        {{unix,darwin},true} ->
            case ba_device_request:approve(playback_control,Peer,Action) of
                ok -> execute(Action,S);
                {error,Reason} -> reply(Peer,Reason),S
            end;
        {_,false} -> reply(Peer,unavailable),S;
        _ -> reply(Peer,unsupported),S
    end,
    {noreply,Next};
handle_cast({remote,#{<<"kind">> := <<"playback_result">>,<<"status">> := Status}=Payload,#{peer := Peer}},S) ->
    ba_session_chat:notice(playback_control,Peer,message(Status,maps:get(<<"track">>,Payload,undefined))),
    {noreply,S};
handle_cast({answer,true,Action},S) -> {noreply,execute(Action,S)};
handle_cast({answer,false,#{from := Peer}},S) -> reply(Peer,declined),{noreply,S};
handle_cast(_,S) -> {noreply,S}.

handle_info(Message,#{engine_request := {Request,Peer}}=S) ->
    case gen_server:check_response(Message,Request) of
        no_reply -> {noreply,S};
        {reply,{ok,Result}} ->
            engine_reply(Peer,Result),{noreply,maps:remove(engine_request,S)};
        _ -> reply(Peer,unavailable),{noreply,maps:remove(engine_request,S)}
    end;
handle_info(_,S) -> {noreply,S}.

execute(#{from := Peer},#{engine_request := _}=S) -> reply(Peer,busy),S;
execute(#{from := Peer,direction := Direction}=Action,S) ->
    case {ba_device_config:policy(playback_control),eligible(Action),ba_session_scope:whereis(ba_audio_engine)} of
        {no,_,_} -> reply(Peer,refused),S;
        {_,true,Engine} when is_pid(Engine) ->
            Request=ba_audio_engine:send_command(Engine,#{op => playback_step,direction => Direction}),
            S#{engine_request => {Request,Peer}};
        _ -> reply(Peer,unavailable),S
    end.

eligible(#{from := Peer,context := #{link := Link,session := Session},incarnation := Inc,deadline := Until}) ->
    try
        true=now_ms()<Until andalso not ba_app_session:excluded(Peer),
        {ok,#{link := Link,session := Session}}=ba_session_control:audio_context(Peer),
        {ok,#{policy := #{members := Members,defaults := Defaults,removed := Removed},
              local_permissions := Local}}=ba_session_membership:current(),
        false=lists:member(Peer,Removed),
        true=lists:member(stream_subscribe,maps:get(Peer,Members,Defaults)),
        true=ba_session_privileges:has(on_air,Local),
        Inc=:=ba_audio_receiver:broadcast_incarnation()
    catch _:_ -> false end.

engine_reply(Peer,#{status := <<"done">>}=Result) ->
    Payload=#{<<"kind">> => <<"playback_result">>,<<"status">> => <<"done">>},
    Reply=case maps:get(track,Result,undefined) of
        Track when is_binary(Track) ->
            case track_text(Track) of true -> Payload#{<<"track">> => Track};false -> Payload end;
        _ -> Payload
    end,
    ba_session_control:session_request([Peer],Reply);
engine_reply(Peer,#{status := <<"no_playable_track">>}) -> reply(Peer,no_playable_track);
engine_reply(Peer,#{status := <<"automation_denied">>}) -> reply(Peer,automation_denied);
engine_reply(Peer,#{status := <<"unsupported">>}) -> reply(Peer,unsupported);
engine_reply(Peer,_) -> reply(Peer,unavailable).

reply(Peer,Reason) ->
    Status=case Reason of consent_required -> <<"refused">>;_ -> atom_to_binary(Reason) end,
    ba_session_control:session_request([Peer],#{<<"kind">> => <<"playback_result">>,<<"status">> => Status}).

track_text(Track) ->
    is_binary(Track) andalso byte_size(Track)>0 andalso byte_size(Track)=<512
        andalso is_list(unicode:characters_to_list(Track)).

message(<<"done">>,Track) when is_binary(Track) -> <<"reports now playing: ",Track/binary>>;
message(<<"done">>,_) -> <<"sent the track command to Music">>;
message(<<"waiting_for_approval">>,_) -> <<"is waiting for approval to change track">>;
message(<<"declined">>,_) -> <<"declined the track request">>;
message(<<"refused">>,_) -> <<"does not allow playback requests">>;
message(<<"busy">>,_) -> <<"already has a playback request in progress">>;
message(<<"unsupported">>,_) -> <<"does not support playback control on this platform">>;
message(<<"no_playable_track">>,_) -> <<"has no supported Music track playing on the captured output">>;
message(<<"automation_denied">>,_) -> <<"needs macOS Automation permission to control Music">>;
message(<<"unavailable">>,_) -> <<"could not change track. Check that it is still broadcasting">>.

now_ms() -> erlang:monotonic_time(millisecond).
