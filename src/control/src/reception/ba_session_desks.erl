%% A bounded set of independent Desk connections; no membership authority here.
-module(ba_session_desks).
-behaviour(gen_server).
-export([start_link/0,reset/0,configure/4,advertise/1,lookup/2,send/3,status/0]).
-export([init/1,handle_call/3,handle_cast/2,handle_info/2,terminate/2,format_status/1]).
start_link() -> gen_server:start_link(ba_session_scope:registration(?MODULE),?MODULE,[],[]).
reset() -> gen_server:call(ba_session_scope:ref(?MODULE),reset).
configure(Session,URLs,Primary,Routes) -> gen_server:call(ba_session_scope:ref(?MODULE),{configure,Session,URLs,Primary,Routes}).
advertise(Cap) -> gen_server:call(ba_session_scope:ref(?MODULE),{advertise,Cap}).
%% A Reception that cannot be reached (e.g. while the network changes) is an
%% ordinary condition: callers get {error,unavailable} instead of a timeout
%% exit, which used to take Session control and its audio down with it.
lookup(URL,Cap) -> available(fun() -> gen_server:call(ba_session_scope:ref(?MODULE),{lookup,URL,Cap},4500) end).
send(To,Type,Packet) -> available(fun() -> gen_server:call(ba_session_scope:ref(?MODULE),{send,To,Type,Packet},3000) end).
available(Call) -> try Call() catch exit:{timeout,_} -> {error,unavailable} end.
status() -> gen_server:call(ba_session_scope:ref(?MODULE),status).
init([]) ->
    true = ba_settings:env("BA_IDENTITY_SEED") =/= false,
    true = ba_settings:env("BA_STATE_DIR") =/= false,
    {Public,_} = ba_device_store:identity(),Id = binary:encode_hex(Public),
    Saved = ba_device_store:load(session_desks,#{id => Id,mailbox => fresh()}),
    Id = maps:get(id,Saved),
    erlang:send_after(1000,self(),repair),
    {ok,#{id => Id,mailbox => maps:get(mailbox,Saved),session => maps:get(session,Saved,undefined),
          primary => maps:get(primary,Saved,undefined),urls => maps:get(urls,Saved,[]),
          routes => maps:get(routes,Saved,#{}),aliases => [],bound => #{},rejected => 0}}.
handle_call(reset,_,S) ->
    [gen_server:cast(P,{detach,self()}) || P <- maps:values(ba_desk_connections_sup:connections())],
    {reply,ok,S#{mailbox := fresh(),session := undefined,primary := undefined,
        urls := [],routes := #{},aliases := [],bound := #{}}};
handle_call({advertise,Cap},_,S) ->
    true=ba_hex:valid(Cap,32),
    {reply,ok,repair(S#{aliases := lists:usort([Cap|maps:get(aliases,S)]),bound := #{}})};
handle_call({lookup,URL,Cap},_,S) ->
    Result=try
        true=lists:member(URL,maps:get(urls,S)),true=ba_hex:valid(Cap,32),
        Pid=maps:get(URL,ba_desk_connections_sup:connections()),
        gen_server:call(Pid,{lookup,maps:get(session,S),Cap},4000)
    catch _:_ -> {error,desk_unavailable} end,
    {reply,Result,S};
handle_call(status,_,S) ->
    Connections = ba_desk_connections_sup:connections(),
    Views = maps:from_list([{URL,connection_status(URL,maps:get(URL,Connections,undefined))} || URL <- maps:get(urls,S)]),
    {reply,#{id => maps:get(id,S),desks => Views,rejected => maps:get(rejected,S),diagnostics => ba_diagnostics:view(S)},S};
handle_call({configure,Session,URLs,Primary,Routes},_,S) ->
    true = ba_hex:valid(Session,32),
    true = is_list(URLs) andalso length(URLs) > 0 andalso length(URLs) =< 4,
    true = length(lists:usort(URLs)) =:= length(URLs),
    true = lists:member(Primary,URLs),
    true = lists:all(fun ba_relay:valid_url/1,URLs),
    true = is_map(Routes) andalso map_size(Routes) =< 16,
    maps:foreach(fun(Id,R) -> true = ba_hex:valid(Id,64),valid_route(R,URLs) end,Routes),
    Saved = maps:with([id,mailbox],S),
    ok = ba_device_store:save(session_desks,Saved#{session => Session,urls => URLs,primary => Primary,routes => Routes}),
    Next = S#{session := Session,primary := Primary,urls := URLs,routes := Routes,bound := #{}},
    {reply,ok,repair(Next)};
%% Every Device in a Session opens the Session mailbox, so any Device ID is
%% addressable there without exchanging routes first.
handle_call({send,To,Type,Packet},From,S) ->
    case {maps:find(To,maps:get(routes,S)),maps:get(aliases,S)} of
        {{ok,R},_} -> handle_call({send_route,To,R,Type,Packet},From,S);
        {error,[Cap|_]} -> handle_call({send_route,To,#{<<"desk">> => maps:get(primary,S),<<"mailbox">> => Cap},Type,Packet},From,S);
        {error,[]} -> {reply,{error,no_route},S}
    end;
handle_call({send_route,To,Route,Type,Packet},_,S) ->
    Result = try
        true = ba_hex:valid(To,64),false = ba_app_session:excluded(To),
        true = is_binary(Packet) andalso byte_size(Packet) =< 32768,
        true = Type =:= <<"session_control">>,
        valid_route(Route,maps:get(urls,S)),
        %% Every configured Desk opens this Device's same scoped mailbox.
        %% Try the advertised route first, then another live Desk; never fan out.
        Preferred = maps:get(<<"desk">>,Route),
        URLs = [Preferred|lists:delete(Preferred,maps:get(urls,S))],
        PacketBody = #{<<"type">> => Type,<<"session">> => maps:get(session,S),<<"packet">> => Packet},
        send_available(URLs,ba_desk_connections_sup:connections(),To,maps:get(<<"mailbox">>,Route),PacketBody)
    catch _:_ -> {error,unavailable} end,
    Next = case Result of ok -> S;_ -> ba_diagnostics:count(route_unavailable,S) end,
    {reply,Result,Next};
handle_call(_,_,S) -> {reply,{error,unsupported},S}.
handle_cast(_,S) -> {noreply,S}.
handle_info({relay,URL,{delivery,From,Cap,Payload}},#{session := Session} = S) ->
    case ba_app_session:excluded(From) orelse
         not (Cap=:=maps:get(mailbox,S) orelse lists:member(Cap,maps:get(aliases,S))) of
        true -> {noreply,ba_diagnostics:count(peer_excluded,S)};
        false -> delivery(URL,From,Payload,Session,S)
    end;
handle_info({relay,URL,Event},S0) ->
    S = case Event of connected -> repair(S0#{bound := maps:remove(URL,maps:get(bound,S0))});_ -> S0 end,
    notify(ba_session_membership,{desk_event,URL,Event}),
    notify(ba_session_control,{desk_event,URL,Event}),{noreply,S};
handle_info(repair,S) ->
    erlang:send_after(1000,self(),repair),{noreply,repair(S)};
handle_info(_,S) -> {noreply,S}.
valid_route(#{<<"desk">> := URL,<<"mailbox">> := Cap} = R,URLs) ->
    true = map_size(R) =:= 2,true = lists:member(URL,URLs),true = ba_hex:valid(Cap,32),ok.
notify(Name,Event) ->
    case ba_session_scope:whereis(Name) of
        undefined -> ok;
        Pid -> case process_info(Pid,message_queue_len) of
            {message_queue_len,N} when N < 64 -> Pid ! Event;
            _ -> {error,desk_recipient_overloaded}
        end
    end.
fresh() -> binary:encode_hex(crypto:strong_rand_bytes(16)).
terminate(_,_) ->
    [gen_server:cast(P,{detach,self()}) || P <- maps:values(ba_desk_connections_sup:connections())],ok.
format_status(Status) -> maps:map(fun(state,S) -> maps:with([id,session,primary],S);(log,_) -> [];(_,_) -> redacted end,Status).

repair(#{session := undefined}=S) -> S;
repair(#{urls := URLs}=S) ->
    Existing = ba_desk_connections_sup:connections(),
    [gen_server:cast(P,{detach,self()}) || {URL,P} <- maps:to_list(Existing),not lists:member(URL,URLs)],
    Bound = maps:from_list([begin
        P = case maps:find(URL,Existing) of
            {ok,Pid} -> Pid;
            error -> ba_desk_connections_sup:ensure(URL,#{owner => self(),url => URL})
        end,
        case is_pid(P) andalso maps:get(URL,maps:get(bound,S),undefined)=/=P of
            true -> gen_server:cast(P,{open,maps:get(session,S),maps:get(mailbox,S),self()}),
                    [gen_server:cast(P,{open,maps:get(session,S),Cap,self()}) || Cap <- maps:get(aliases,S)],
                    gen_server:cast(P,{watch,maps:keys(maps:get(routes,S)),self()});
            false -> ok
        end,{URL,P}
    end || URL <- URLs]),S#{bound := Bound}.
connection_status(URL,P) ->
    try gen_server:call(P,status,500) catch exit:_ -> #{url => URL,connected => false,error => unavailable} end.
send_available([],_,_,_,_) -> {error,unavailable};
send_available([URL|Rest],Connections,To,Cap,Payload) ->
    Result = try gen_server:call(maps:get(URL,Connections),{send,To,Cap,Payload},500)
        catch _:_ -> {error,unavailable} end,
    case Result of ok -> ok;_ -> send_available(Rest,Connections,To,Cap,Payload) end.

delivery(URL,From,Payload,Session,S) ->
    Delivery = case Payload of
        #{<<"type">> := Type,<<"session">> := Session,<<"packet">> := Packet} when map_size(Payload) =:= 3 ->
            Target = case Type of <<"session_control">> -> ba_session_control;_ -> undefined end,
            case Target =/= undefined andalso is_binary(Packet) andalso byte_size(Packet) =< 32768 of
                true -> notify(Target,{desk_delivery,URL,From,Packet});
                false -> {error,invalid_desk_payload}
            end;
        _ -> {error,invalid_desk_payload}
    end,
    Next = case Delivery of {error,R} -> ba_diagnostics:count(R,S);_ -> S end,
    {noreply,Next}.

