%% Bounded observation only: never starts audio, changes consent or retimes PCM.
%% Separate from the automation Worker so manually controlled/CLI Devices expose
%% exactly the same diagnostic projection. Remote ingress reads the Handler cache.
-module(ba_audio_observer).
-behaviour(gen_server).
-export([start_link/0,levels_interest/0,request_levels/0,reported_levels/2,session_levels/0,init/1,handle_call/3,handle_cast/2,handle_info/2]).
start_link() -> gen_server:start_link(ba_session_scope:registration(?MODULE),?MODULE,[],[]).
levels_interest() -> cast(levels_interest).
request_levels() -> cast(request_levels).
reported_levels(Author,Body) -> cast({reported_levels,Author,Body}).
session_levels() ->
    try gen_server:call(ba_session_scope:ref(?MODULE),session_levels,100)
    catch exit:_ -> #{} end.
cast(Message) -> gen_server:cast(ba_session_scope:ref(?MODULE),Message).

init([]) ->
    Owner=ba_session_scope:whereis(ba_device_handler), monitor(process,Owner),self() ! sample,{ok,#{owner => Owner}}.
handle_call(session_levels,_,S) ->
    Now=now_ms(),
    Levels=maps:map(fun(_,Rows) ->
        maps:map(fun(_,#{level := Level,received := At}) ->
            Age=maps:get(<<"meter_age_ms">>,Level),
            Level#{<<"meter_age_ms">> := Age+max(0,Now-At)}
        end,Rows)
    end,maps:get(session_levels,S,#{})),
    {reply,Levels,S};
handle_call(_,_,S) -> {reply,{error,unsupported},S}.
handle_cast(request_levels,S) ->
    Now=now_ms(),
    case Now>=maps:get(interest_due,S,Now) of
        true -> ba_session_membership:announce(<<"levels_interest">>),{noreply,S#{interest_due => Now+1000}};
        false -> {noreply,S}
    end;
handle_cast(levels_interest,S) ->
    %% Give a newly started native path one sampling cycle. Each distinct
    %% interest reaches this process at most once through Session membership.
    erlang:send_after(250,self(),publish_levels),{noreply,S};
handle_cast({reported_levels,Author,#{<<"levels">> := Levels,<<"sampled_at_ms">> := Sampled}},S) ->
    Known=maps:get(session_levels,S,#{}),
    Current=maps:get(Author,Known,#{}),Now=now_ms(),
    Rows=maps:fold(fun(Key,Level,Acc) ->
        case Sampled>maps:get(sampled,maps:get(Key,Acc,#{}),0) of
            true -> Acc#{Key => #{level => Level,sampled => Sampled,received => Now}};
            false -> Acc
        end
    end,Current,Levels),
    {noreply,S#{session_levels => Known#{Author => Rows}}};
handle_cast(_,S) -> {noreply,S}.
handle_info(sample,#{owner := Owner}=S) ->
    erlang:send_after(250,self(),sample),
    Flags=ba_audio_diagnostics:options(),
    try
        View=case lists:any(fun(V) -> V end,maps:values(Flags)) of
            true -> case ba_session_scope:whereis(ba_audio_receiver) of undefined -> #{};_ -> ba_audio_receiver:snapshot() end;
            false -> #{}
        end,
        Observed=View#{levels => levels(S)},
        Clock=case ba_audio_diagnostics:enabled(analysis) of true -> ba_session_clock:status();false -> #{} end,
        Owner ! {audio_observation,self(),Observed,ba_audio_diagnostics:snapshot(Observed,Clock),ba_audio_diagnostics:trace(View)}
    catch exit:_ -> ok end,
    {noreply,read_levels(S)};
handle_info(publish_levels,S) ->
    %% The note goes to the Session. A per-request Inspect approval does
    %% not authorize broadcasting the Device's meters to other members.
    try ba_device_permission:allowed(inspect) andalso ba_device_config:policy(inspect)=:=always of
        true ->
            Levels=maps:from_list([{atom_to_binary(Key),#{<<"peak_db">> => Peak,<<"rms_db">> => Rms,<<"meter_age_ms">> => Age}}
                || {Key,#{peak_db := Peak,rms_db := Rms,meter_age_ms := Age}} <- maps:to_list(levels(S)),Age=<1000]),
            case map_size(Levels)>0 of
                true -> ba_session_membership:announce(<<"levels">>,#{<<"levels">> => Levels,
                    <<"sampled_at_ms">> => erlang:system_time(millisecond)});
                false -> ok
            end;
        false -> ok
    catch exit:_ -> ok end,
    {noreply,S};
handle_info({'DOWN',_,process,Owner,_},#{owner := Owner}=S) -> {stop,normal,S};
handle_info(Message,#{level_request := Request}=S) ->
    case gen_server:check_response(Message,Request) of
        no_reply -> {noreply,S};
        {reply,{ok,Levels}} when is_map(Levels) ->
            {noreply,(maps:remove(level_request,S))#{level_snapshot => {Levels,now_ms()}}};
        _ -> {noreply,maps:without([level_request,level_snapshot],S)}
    end;
handle_info(_,S) -> {noreply,S}.

%% One request in flight, including while the native engine is waiting for
%% hardware permissions. Both local UI and remote Inspect use the same cache.
read_levels(#{level_request := _}=S) -> S;
read_levels(S) ->
    case ba_session_scope:whereis(ba_audio_engine) of
        undefined -> maps:remove(level_snapshot,S);
        Engine -> S#{level_request => ba_audio_engine:send_command(Engine,#{op => levels})}
    end.

levels(#{level_snapshot := {Levels,At}}) ->
    Elapsed=max(0,now_ms()-At),
    maps:map(fun(_,#{meter_age_ms := Age}=Level) -> Level#{meter_age_ms := Age+Elapsed} end,Levels);
levels(_) -> #{}.

now_ms() -> erlang:monotonic_time(millisecond).
