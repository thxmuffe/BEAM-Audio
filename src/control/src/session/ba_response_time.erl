%% The Session's Response time: the delay between capture and playback that
%% every speaker in the Session uses.
%%
%% The setting is a signed Session setting held in the membership statement
%% (like the Session name), changed by grant or on_air holders.
%%
%% Each playing Device reports batches of packet timings. The Session estimate
%% combines the sample counts and exact sums from fresh, distinct batches.
-module(ba_response_time).
-behaviour(gen_server).
-export([start_link/0,default/0,valid/1,current/0,view/0,playback_states/0,set/1,setting/3,playback/3,remote_playback/2,reported/2]).
-export([init/1,handle_call/3,handle_cast/2,handle_info/2]).
-define(MAX_MS,3000).
-define(FIRST_REPORT_MS,250).
-define(MATURE_SAMPLES,256).
-define(MAX_REPORT_MS,2000).
-define(FRESH_S,120).

start_link() -> gen_server:start_link(ba_session_scope:registration(?MODULE),?MODULE,[],[]).

default() -> 150.
valid(Ms) when is_integer(Ms),Ms>=0,Ms=<?MAX_MS -> ok;
valid(_) -> {error,invalid_response_time}.

%% The Response time in force, for starting and moving speakers.
current() ->
    case snapshot() of
        #{ready := true,offset_ms := Ms} -> {ok,Ms};
        _ -> {error,unavailable}
    end.
%% Setting and measurement, for the monitor and the UI.
view() ->
    D=snapshot(),
    Reports=maps:values(maps:get(reports,D,#{})),
    {Count,Sum}=lists:foldl(fun({N,Ns,_},{Total,TotalNs}) -> {Total+N,TotalNs+Ns} end,{0,0},Reports),
    #{offset_ms => maps:get(offset_ms,D,null),revision => maps:get(revision,D,null),ready => maps:get(ready,D,false),
      measured_ms => case Count of 0 -> null;_ -> round(Sum/Count/1000000) end,
      measurement_count => Count,measurement_sum_ns => Sum}.
playback_states() ->
    maps:map(fun(_,#{playing := Playing,failed := Failed}) -> #{playing => Playing,failed => Failed} end,
        maps:get(playback_states,snapshot(),#{})).
set(Ms) -> ba_session_membership:set_response_time(Ms).

%% From membership: the signed setting changed.
setting(Ms,Revision,Ready) -> gen_server:cast(ba_session_scope:ref(?MODULE),{setting,Ms,Revision,Ready}).
%% From gossip: another Device's measured value.
reported(Id,Body) -> cast({reported,Id,Body}).
playback(Known,Playing,Failed) -> cast({playback,self(),Known,Playing,Failed}).
remote_playback(Device,Body) -> cast({remote_playback,Device,Body}).
cast(Message) -> gen_server:cast(ba_session_scope:ref(?MODULE),Message).

init([]) ->
    ba_session_scope:new_table(?MODULE,[named_table,protected,{read_concurrency,true}]),
    {Pub,_}=ba_device_store:identity(),
    erlang:send_after(?FIRST_REPORT_MS,self(),tick),
    %% Membership starts first and may have published the setting already.
    {Ms,Revision,Ready}=try ba_session_membership:response_setting() catch exit:_ -> {default(),null,false} end,
    {ok,save(#{self => binary:encode_hex(Pub),offset_ms => Ms,revision => Revision,ready => Ready,
               reports => #{},next => undefined,samples => 0,playback_states => #{},
               active => [],started => [],failed => false,receiver => undefined,revision_playback => 0})}.

handle_call(_,_,S) -> {reply,{error,unsupported},S}.

handle_cast({setting,Ms,Revision,Ready},S) -> {noreply,save(S#{offset_ms := Ms,revision := Revision,ready := Ready})};
handle_cast({reported,Id,#{<<"count">> := N,<<"sum_ns">> := Sum,<<"at">> := At}},S) ->
    {noreply,save(add_report(Id,N,Sum,At,S))};
handle_cast({playback,Pid,Known,Active,Failed},#{receiver := Receiver}=S) ->
    Next=case Receiver of
        {Pid,_} -> S;
        undefined -> S#{receiver := {Pid,monitor(process,Pid)}};
        {_,Ref} -> demonitor(Ref,[flush]),S#{receiver := {Pid,monitor(process,Pid)}}
    end,
    {noreply,save(local_playback(Known,Active,Failed,Next))};
handle_cast({remote_playback,Device,#{<<"playing">> := Playing,<<"failed">> := Failed,
        <<"started">> := Started,<<"revision">> := Revision}},#{playback_states := States}=S) ->
    case Revision > maps:get(revision,maps:get(Device,States,#{}),0) of
        true ->
            Next=S#{playback_states := States#{Device => #{playing => Playing,failed => Failed,revision => Revision}}},
            {noreply,save(reset_cadence(Started,Next))};
        false -> {noreply,S}
    end;
handle_cast(_,S) -> {noreply,S}.

handle_info(tick,S) ->
    erlang:send_after(?FIRST_REPORT_MS,self(),tick),
    {noreply,save(report(expire(S)))};
handle_info({'DOWN',Ref,process,Pid,_},#{receiver := {Pid,Ref}}=S) ->
    {noreply,save(local_playback([],[],false,S#{receiver := undefined}))};
handle_info(_,S) -> {noreply,S}.

local_playback(Known,Active,Failed,#{active := Old,started := Previous,failed := OldFailed,
        self := Self,playback_states := States}=S) ->
    Started=(Active--Previous)=/=[],
    Playing=Active=/=[],
    Remembered=lists:usort(Active++[Id || Id <- Previous,lists:member(Id,Known)]),
    Next=S#{active := Active,started := Remembered,failed := Failed},
    case Started orelse Playing=/=(Old=/=[]) orelse Failed=/=OldFailed of
        true ->
            Revision=max(erlang:system_time(microsecond),maps:get(revision_playback,S)+1),
            Fields=#{<<"playing">> => Playing,<<"failed">> => Failed,<<"started">> => Started,<<"revision">> => Revision},
            publish(<<"playback">>,Fields),
            reset_cadence(Started,Next#{revision_playback := Revision,playback_states :=
                States#{Self => #{playing => Playing,failed => Failed,revision => Revision}}});
        false -> Next
    end.

reset_cadence(true,S) -> S#{next := undefined,samples := 0};
reset_cadence(false,S) -> S.

report(#{active := []}=S) -> S#{next := undefined};
report(#{next := Due}=S) ->
    Now=now_ms(),
    case Due=:=undefined orelse Now>=Due of
        false -> S;
        true ->
            case measure() of
                {0,_} -> S;
                {Count,Sum} ->
                    %% A note's signed ID is its batch ID on every route.
                    Id=publish(<<"response">>,#{<<"count">> => Count,<<"sum_ns">> => Sum}),
                    Next=add_report(Id,Count,Sum,erlang:system_time(second),S),
                    Step=min(?MAX_REPORT_MS,?FIRST_REPORT_MS*(1+maps:get(samples,Next) div ?MATURE_SAMPLES)),
                    Next#{next := Now+Step}
            end
    end.

publish(Kind,Fields) ->
    ba_session_membership:announce(Kind,Fields).

add_report(Id,N,Sum,At,#{reports := Reports,samples := Samples}=S) ->
    case maps:is_key(Id,Reports) of
        true -> S;
        false -> S#{reports := Reports#{Id => {N,Sum,At}},samples := Samples+N}
    end.

%% Reading the engine drains each speaker's current window exactly once.
measure() ->
    case ba_session_scope:whereis(ba_audio_engine) of
        undefined -> {0,0};
        Engine ->
            try ba_audio_engine:command(Engine,#{op => response},500) of
                {ok,#{speakers := Speakers}} ->
                    lists:foldl(fun
                        (#{count := N,sum_ns := Ns},{Count,Sum}) -> {Count+N,Sum+Ns};
                        (_,Totals) -> Totals
                    end,{0,0},Speakers);
                _ -> {0,0}
            catch exit:_ -> {0,0} end
    end.

expire(#{reports := R}=S) ->
    Old=erlang:system_time(second)-?FRESH_S,
    S#{reports := maps:filter(fun(_,{_,_,At}) -> At>Old end,R)}.

now_ms() -> erlang:monotonic_time(millisecond).
save(S) -> ets:insert(ba_session_scope:table(?MODULE),{state,maps:with([offset_ms,revision,ready,reports,playback_states],S)}),S.
snapshot() ->
    try ets:lookup(ba_session_scope:table(?MODULE),state) of [{state,D}] -> D;_ -> #{}
    catch error:badarg -> #{} end.
