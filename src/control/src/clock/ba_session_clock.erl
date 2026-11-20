%% Session time is UTC. Every Device reads UTC for itself: from SNTP once a
%% minute, or from its own system clock when no time server answers. Nobody
%% follows anybody, so there is no master, handover or sample protocol.
%% Millisecond accuracy is enough (owner decision 2026-11-20).
%%
%% The mapping from Erlang monotonic time to UTC is published in an ETS table
%% for readers. Small corrections slew it (no audible step); a large one, such
%% as the first answer from the time server, steps it.
-module(ba_session_clock).
-behaviour(gen_server).
-export([start_link/0,id/0,session_time/1,presentation/1,status/0,resync/1]).
-export([init/1,handle_call/3,handle_cast/2,handle_info/2,terminate/2]).
-define(TIMELINE,<<"utc">>).
-define(STEP_NS,50000000).
-define(QUERY_TIMEOUT_MS,2000).
-define(BURST,4).

start_link() -> gen_server:start_link(ba_session_scope:registration(?MODULE),?MODULE,[],[]).

%% Every Device runs the same timeline: UTC.
id() -> ?TIMELINE.

%% Session time (UTC nanoseconds) at an Erlang monotonic time.
session_time(Monotonic) ->
    case snapshot() of
        #{mapping := M} -> {ok,ba_session_clock_mapping:from_monotonic(M,Monotonic)};
        _ -> {error,clock_unavailable}
    end.

%% Session times for Erlang monotonic times, with the Session's Response time.
presentation(Times) ->
    case {snapshot(),ba_response_time:current()} of
        {#{mapping := M},{ok,Ms}} ->
            {ok,#{clock => ?TIMELINE,offset_ms => Ms,times => [ba_session_clock_mapping:from_monotonic(M,T) || T <- Times]}};
        _ -> {error,clock_or_offset_unavailable}
    end.

status() ->
    case snapshot() of
        #{mapping := M,synced_at := At}=D ->
            Now=mono(),
            (maps:with([source,reference,round_trip_ns,uncertainty_ns,last_error,corrections,steps],D))#{
                state => synchronized,timeline => ?TIMELINE,last_sync => At,age_ns => Now-At,
                utc_time_ns => ba_session_clock_mapping:from_monotonic(M,Now),
                remaining_correction_ns => ba_session_clock_mapping:remaining(M,Now),
                offset_policy => ba_response_time:view()};
        _ -> #{state => acquiring,offset_policy => ba_response_time:view()}
    end.

%% After a resume or a network change: read UTC again now.
resync(Reason) when Reason=:=resume;Reason=:=network_changed;Reason=:=explicit ->
    gen_server:cast(ba_session_scope:ref(?MODULE),resync).

init([]) ->
    ba_session_scope:new_table(?MODULE,[named_table,protected,{read_concurrency,true}]),
    Reference=case ba_settings:app(clock_reference,{ntp,"ntp.metas.ch"}) of {ntp,H} -> {ntp,H,123};R -> R end,
    Interval=ba_settings:app(clock_interval_ms,60000),
    PPM=ba_settings:app(clock_slew_ppm,500),
    true=valid_reference(Reference),
    true=is_integer(Interval) andalso Interval>=100 andalso Interval=<600000,
    true=is_integer(PPM) andalso PPM>0 andalso PPM<1000000,
    %% Usable at once from the system clock; the time server refines it.
    S=#{reference => Reference,interval => Interval,ppm => PPM,query => undefined,blocked => false,
        clock => #{reference => reference_name(Reference),last_error => null,corrections => 0,steps => 0}},
    self() ! read,
    {ok,apply_reading(system,measure(system),S)}.

handle_call(_,_,S) -> {reply,{error,unsupported},S}.

%% The monotonic clock may have paused (suspend) or the network changed:
%% re-read the system clock now, then ask the time server.
handle_cast(resync,S) -> handle_info(read,apply_reading(system,measure(system),S));
handle_cast(_,S) -> {noreply,S}.

handle_info(read,#{query := undefined,blocked := false,reference := {ntp,_,_}=R}=S) ->
    Owner=self(),
    {Pid,Ref}=ba_session_scope:spawn_monitor(fun() ->
        Owner ! {reading,self(),try measure(R) catch _:_ -> {error,query_failed} end} end),
    {noreply,S#{query := {Pid,Ref}}};
handle_info(read,S) -> {noreply,schedule(S)};
handle_info({reading,Pid,Result},#{query := {Pid,Ref}}=S) ->
    demonitor(Ref,[flush]),
    Next=case Result of
        {ok,_} -> apply_reading(ntp,Result,S);
        {error,{kiss_of_death,_}} -> failed(kiss_of_death,S#{blocked := true});
        {error,Reason} -> failed(Reason,S)
    end,
    {noreply,schedule(Next#{query := undefined})};
handle_info({'DOWN',Ref,process,_,_},#{query := {_,Ref}}=S) ->
    {noreply,schedule(failed(query_failed,S#{query := undefined}))};
handle_info(_,S) -> {noreply,S}.

terminate(_,#{query := {Pid,_}}) -> exit(Pid,kill),ok;
terminate(_,_) -> ok.

schedule(#{interval := I}=S) -> erlang:send_after(I,self(),read),S.

apply_reading(Source,{ok,#{offset_ns := Offset,sampled_at := At}=R},#{clock := D,ppm := PPM}=S) ->
    {Mapping,Kind}=case maps:get(mapping,D,undefined) of
        undefined -> {ba_session_clock_mapping:new(At,Offset),step};
        M ->
            case abs(Offset-ba_session_clock_mapping:offset(M,At)) of
                E when E>?STEP_NS -> {ba_session_clock_mapping:new(At,Offset),step};
                _ -> {ba_session_clock_mapping:correct(M,At,Offset,PPM),slew}
            end
    end,
    Count=case Kind of step -> steps;slew -> corrections end,
    save(S#{clock := D#{mapping => Mapping,synced_at => At,source => Source,last_error := null,
        round_trip_ns => maps:get(round_trip_ns,R,0),uncertainty_ns => maps:get(uncertainty_ns,R,null),
        Count := maps:get(Count,D)+1}}).
%% The mapping keeps running on the monotonic clock; only the error is shown.
failed(Reason,#{clock := D}=S) -> save(S#{clock := D#{last_error := Reason}}).

measure(system) ->
    A=mono(),UTC=erlang:system_time(nanosecond),B=mono(),
    {ok,#{offset_ns => UTC-(A+B) div 2,sampled_at => B,round_trip_ns => B-A}};
%% A short burst; the reading with the shortest round trip has the least
%% path asymmetry (measured: slow replies are off by up to ~8 ms).
measure({ntp,Host,Port}) ->
    Replies=[R || _ <- lists:seq(1,?BURST),{ok,_}=R <- [begin timer:sleep(100),ba_sntp:query(Host,Port,?QUERY_TIMEOUT_MS) end]],
    case lists:sort(fun({ok,A},{ok,B}) -> maps:get(round_trip_ns,A)=<maps:get(round_trip_ns,B) end,Replies) of
        [Best|_] -> Best;
        [] -> ba_sntp:query(Host,Port,?QUERY_TIMEOUT_MS)
    end.

save(#{clock := D}=S) -> ets:insert(ba_session_scope:table(?MODULE),{clock,D}),S.
snapshot() ->
    try ets:lookup(ba_session_scope:table(?MODULE),clock) of [{clock,D}] -> D;_ -> #{}
    catch error:badarg -> #{} end.

valid_reference(system) -> true;
valid_reference({ntp,H,P}) -> valid_host(H) andalso is_integer(P) andalso P>0 andalso P<65536;
valid_reference(_) -> false.
valid_host(H) -> is_list(H) andalso H=/=[] andalso length(H)=<253 andalso lists:all(fun(C) -> is_integer(C) andalso C>0 andalso C<128 end,H).
reference_name(system) -> <<"system">>;
reference_name({ntp,H,_}) -> list_to_binary(H).
mono() -> erlang:monotonic_time(nanosecond).
