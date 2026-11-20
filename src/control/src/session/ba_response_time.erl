%% The Session's Response time: the delay between capture and playback that
%% every speaker in the Session uses.
%%
%% The setting is a signed Session setting held in the membership statement
%% (like the Session name), changed by grant or on_air holders.
%%
%% The measurement says what it could have been. Each receiving Device's engine
%% measures, per packet, the Response time that packet needed (arrival after
%% capture, plus output lead). A Device's value is the one that would have
%% played 99% of its packets in time. Devices gossip their values: soon after a
%% stream starts, then less often, at least once a minute. Every Device keeps
%% the fresh values it hears (the distribution) and shows their average.
-module(ba_response_time).
-behaviour(gen_server).
-export([start_link/0,default/0,valid/1,current/0,view/0,set/1,setting/3,reported/3]).
-export([init/1,handle_call/3,handle_cast/2,handle_info/2]).
-define(MAX_MS,3000).
-define(FIRST_REPORT_MS,2000).
-define(MAX_REPORT_MS,60000).
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
    Values=[Ms || {Ms,_} <- maps:values(maps:get(reports,D,#{}))],
    #{offset_ms => maps:get(offset_ms,D,null),revision => maps:get(revision,D,null),ready => maps:get(ready,D,false),
      measured_ms => case Values of [] -> null;_ -> round(lists:sum(Values)/length(Values)) end,
      measured => lists:sort(Values)}.
set(Ms) -> ba_session_membership:set_response_time(Ms).

%% From membership: the signed setting changed.
setting(Ms,Revision,Ready) -> gen_server:cast(ba_session_scope:ref(?MODULE),{setting,Ms,Revision,Ready}).
%% From gossip: another Device's measured value.
reported(Device,Ms,At) -> gen_server:cast(ba_session_scope:ref(?MODULE),{reported,Device,Ms,At}).

init([]) ->
    ba_session_scope:new_table(?MODULE,[named_table,protected,{read_concurrency,true}]),
    {Pub,_}=ba_device_store:identity(),
    erlang:send_after(1000,self(),tick),
    %% Membership starts first and may have published the setting already.
    {Ms,Revision,Ready}=try ba_session_membership:response_setting() catch exit:_ -> {default(),null,false} end,
    {ok,save(#{self => binary:encode_hex(Pub),offset_ms => Ms,revision => Revision,ready => Ready,
               reports => #{},next => undefined,step => ?FIRST_REPORT_MS})}.

handle_call(_,_,S) -> {reply,{error,unsupported},S}.

handle_cast({setting,Ms,Revision,Ready},S) -> {noreply,save(S#{offset_ms := Ms,revision := Revision,ready := Ready})};
handle_cast({reported,Device,Ms,At},S) when is_integer(Ms),is_integer(At) ->
    {noreply,save(S#{reports := (maps:get(reports,S))#{Device => {Ms,At}}})};
handle_cast(_,S) -> {noreply,S}.

handle_info(tick,S) ->
    erlang:send_after(1000,self(),tick),
    {noreply,save(expire(report(S)))};
handle_info(_,S) -> {noreply,S}.

%% A stream starting makes reports frequent again; they then double in
%% interval up to a minute.
report(#{next := undefined}=S) ->
    case measure() of
        {ok,_} -> S#{next := now_ms()+?FIRST_REPORT_MS,step := ?FIRST_REPORT_MS};
        none -> S
    end;
report(#{next := Due}=S) ->
    case now_ms()>=Due andalso measure() of
        false -> S;
        none -> S#{next := undefined};
        {ok,Ms} ->
            Value=min(Ms,?MAX_MS),Step=min(2*maps:get(step,S),?MAX_REPORT_MS),
            _=try ba_session_membership:announce(<<"response">>,#{<<"response_ms">> => Value}) catch exit:_ -> ok end,
            Reports=(maps:get(reports,S))#{maps:get(self,S) => {Value,erlang:system_time(second)}},
            S#{reports := Reports,next := now_ms()+Step,step := Step}
    end.

%% This Device's speakers since the last read: the largest p99 among streams
%% that received packets. The window accumulates until a report takes it.
measure() ->
    case ba_session_scope:whereis(ba_audio_engine) of
        undefined -> none;
        Engine ->
            try ba_audio_engine:command(Engine,#{op => response},500) of
                {ok,#{speakers := Speakers}} ->
                    case [P || #{count := N,p99_ms := P} <- Speakers,N>0] of
                        [] -> none;
                        Values -> {ok,lists:max(Values)}
                    end;
                _ -> none
            catch exit:_ -> none end
    end.

expire(#{reports := R}=S) ->
    Old=erlang:system_time(second)-?FRESH_S,
    S#{reports := maps:filter(fun(_,{_,At}) -> At>Old end,R)}.

now_ms() -> erlang:monotonic_time(millisecond).
save(S) -> ets:insert(ba_session_scope:table(?MODULE),{state,maps:with([offset_ms,revision,ready,reports],S)}),S.
snapshot() ->
    try ets:lookup(ba_session_scope:table(?MODULE),state) of [{state,D}] -> D;_ -> #{}
    catch error:badarg -> #{} end.
