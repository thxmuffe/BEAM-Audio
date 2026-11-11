%% A bounded set of independent Desk connections; no membership authority here.
-module(ba_buffee_desks).
-behaviour(gen_server).
-export([start_link/0,reset/0,configure/4,route/0,advertise/1,lookup/2,send/3,send_route/4,status/0,peer_online/1]).
-export([init/1,handle_call/3,handle_cast/2,handle_info/2,terminate/2,format_status/1]).
start_link() -> gen_server:start_link({local,?MODULE},?MODULE,[],[]).
reset() -> gen_server:call(?MODULE,reset).
configure(Buffee,URLs,Primary,Routes) -> gen_server:call(?MODULE,{configure,Buffee,URLs,Primary,Routes}).
route() -> gen_server:call(?MODULE,route).
advertise(Cap) -> gen_server:call(?MODULE,{advertise,Cap}).
lookup(URL,Cap) -> gen_server:call(?MODULE,{lookup,URL,Cap},4500).
send(To,Type,Packet) -> gen_server:call(?MODULE,{send,To,Type,Packet},3000).
send_route(To,Route,Type,Packet) -> gen_server:call(?MODULE,{send_route,To,Route,Type,Packet},3000).
status() -> gen_server:call(?MODULE,status).
peer_online(Peer) -> gen_server:call(?MODULE,{peer_online,Peer}).
init([]) ->
    true = os:getenv("BA_IDENTITY_SEED") =/= false,
    true = os:getenv("BA_STATE_DIR") =/= false,
    {Public,_} = ba_device_store:identity(),Id = binary:encode_hex(Public),
    Saved = ba_device_store:load(buffee_desks,#{id => Id,mailbox => fresh()}),
    Id = maps:get(id,Saved),
    erlang:send_after(1000,self(),repair),
    {ok,#{id => Id,mailbox => maps:get(mailbox,Saved),buffee => maps:get(buffee,Saved,undefined),
          primary => maps:get(primary,Saved,undefined),urls => maps:get(urls,Saved,[]),
          routes => maps:get(routes,Saved,#{}),aliases => [],bound => #{},rejected => 0}}.
handle_call(reset,_,S) ->
    [ba_desk_connections_sup:stop(URL) || URL <- maps:keys(ba_desk_connections_sup:connections())],
    {reply,ok,S#{mailbox := fresh(),buffee := undefined,primary := undefined,
        urls := [],routes := #{},aliases := [],bound := #{}}};
handle_call({advertise,Cap},_,S) ->
    true=ba_buffee_job:hex(Cap,32),
    {reply,ok,repair(S#{aliases := lists:usort([Cap|maps:get(aliases,S)]),bound := #{}})};
handle_call({lookup,URL,Cap},_,S) ->
    Result=try
        true=lists:member(URL,maps:get(urls,S)),true=ba_buffee_job:hex(Cap,32),
        Pid=maps:get(URL,ba_desk_connections_sup:connections()),
        gen_server:call(Pid,{lookup,maps:get(buffee,S),Cap},4000)
    catch _:_ -> {error,desk_unavailable} end,
    {reply,Result,S};
handle_call(route,_,S) -> {reply,#{<<"desk">> => maps:get(primary,S),<<"mailbox">> => maps:get(mailbox,S)},S};
handle_call({peer_online,Peer},_,S) ->
    Connections = ba_desk_connections_sup:connections(),
    Online = lists:any(fun(URL) ->
        V = connection_status(URL,maps:get(URL,Connections,undefined)),
        maps:get(connected,V,false) andalso lists:member(Peer,maps:get(online,V,[]))
    end,maps:get(urls,S)),{reply,Online,S};
handle_call(status,_,S) ->
    Connections = ba_desk_connections_sup:connections(),
    Views = maps:from_list([{URL,connection_status(URL,maps:get(URL,Connections,undefined))} || URL <- maps:get(urls,S)]),
    {reply,#{id => maps:get(id,S),desks => Views,rejected => maps:get(rejected,S),diagnostics => ba_diagnostics:view(S)},S};
handle_call({configure,Buffee,URLs,Primary,Routes},_,S) ->
    true = ba_buffee_job:hex(Buffee,32),
    true = is_list(URLs) andalso length(URLs) > 0 andalso length(URLs) =< 4,
    true = length(lists:usort(URLs)) =:= length(URLs),
    true = lists:member(Primary,URLs),
    true = lists:all(fun ba_relay:valid_url/1,URLs),
    true = is_map(Routes) andalso map_size(Routes) =< 16,
    maps:foreach(fun(Id,R) -> true = ba_buffee_job:hex(Id,64),valid_route(R,URLs) end,Routes),
    Saved = maps:with([id,mailbox],S),
    ok = ba_device_store:save(buffee_desks,Saved#{buffee => Buffee,urls => URLs,primary => Primary,routes => Routes}),
    Next = S#{buffee := Buffee,primary := Primary,urls := URLs,routes := Routes,bound := #{}},
    {reply,ok,repair(Next)};
handle_call({send,To,Type,Packet},From,S) ->
    case maps:find(To,maps:get(routes,S)) of
        {ok,R} -> handle_call({send_route,To,R,Type,Packet},From,S);
        error -> {reply,{error,no_route},S}
    end;
handle_call({send_route,To,Route,Type,Packet},_,S) ->
    Result = try
        true = ba_buffee_job:hex(To,64),false = ba_app_session:excluded(To),
        true = is_binary(Packet) andalso byte_size(Packet) =< 32768,
        true = Type =:= <<"membership">> orelse Type =:= <<"buffee_control">>,
        valid_route(Route,maps:get(urls,S)),
        %% Every configured Desk opens this Device's same scoped mailbox.
        %% Try the advertised route first, then another live Desk; never fan out.
        Preferred = maps:get(<<"desk">>,Route),
        URLs = [Preferred|lists:delete(Preferred,maps:get(urls,S))],
        PacketBody = #{<<"type">> => Type,<<"buffee">> => maps:get(buffee,S),<<"packet">> => Packet},
        send_available(URLs,ba_desk_connections_sup:connections(),To,maps:get(<<"mailbox">>,Route),PacketBody)
    catch _:_ -> {error,unavailable} end,
    Next = case Result of ok -> S;_ -> ba_diagnostics:count(route_unavailable,S) end,
    {reply,Result,Next};
handle_call(_,_,S) -> {reply,{error,unsupported},S}.
handle_cast(_,S) -> {noreply,S}.
handle_info({relay,URL,{delivery,From,Cap,Payload}},#{buffee := Buffee} = S) ->
    case ba_app_session:excluded(From) orelse
         not (Cap=:=maps:get(mailbox,S) orelse lists:member(Cap,maps:get(aliases,S))) of
        true -> {noreply,ba_diagnostics:count(peer_excluded,S)};
        false -> delivery(URL,From,Payload,Buffee,S)
    end;
handle_info({relay,URL,Event},S0) ->
    S = case Event of connected -> repair(S0#{bound := maps:remove(URL,maps:get(bound,S0))});_ -> S0 end,
    notify(ba_buffee_membership,{desk_event,URL,Event}),
    notify(ba_buffee_control,{desk_event,URL,Event}),{noreply,S};
handle_info(repair,S) ->
    erlang:send_after(1000,self(),repair),{noreply,repair(S)};
handle_info(_,S) -> {noreply,S}.
valid_route(#{<<"desk">> := URL,<<"mailbox">> := Cap} = R,URLs) ->
    true = map_size(R) =:= 2,true = lists:member(URL,URLs),true = ba_buffee_job:hex(Cap,32),ok.
notify(Name,Event) ->
    case whereis(Name) of
        undefined -> ok;
        Pid -> case process_info(Pid,message_queue_len) of
            {message_queue_len,N} when N < 64 -> Pid ! Event;
            _ -> {error,desk_recipient_overloaded}
        end
    end.
fresh() -> binary:encode_hex(crypto:strong_rand_bytes(16)).
terminate(_,_) -> ok.
format_status(Status) -> maps:map(fun(state,S) -> maps:with([id,buffee,primary],S);(log,_) -> [];(_,_) -> redacted end,Status).

repair(#{buffee := undefined}=S) -> S;
repair(#{urls := URLs}=S) ->
    Existing = ba_desk_connections_sup:connections(),
    [ba_desk_connections_sup:stop(URL) || URL <- maps:keys(Existing),not lists:member(URL,URLs)],
    Bound = maps:from_list([begin
        P = case maps:find(URL,Existing) of
            {ok,Pid} -> Pid;
            error -> ba_desk_connections_sup:ensure(URL,#{owner => ?MODULE,delivery => raw,register => false,
                url => URL,tag => URL,max_owner_queue => 64})
        end,
        case is_pid(P) andalso maps:get(URL,maps:get(bound,S),undefined)=/=P of
            true -> gen_server:cast(P,{open,maps:get(buffee,S),maps:get(mailbox,S)}),
                    [gen_server:cast(P,{open,maps:get(buffee,S),Cap}) || Cap <- maps:get(aliases,S)],
                    gen_server:cast(P,{watch,maps:keys(maps:get(routes,S))});
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

delivery(URL,From,Payload,Buffee,S) ->
    Delivery = case Payload of
        #{<<"type">> := Type,<<"buffee">> := Buffee,<<"packet">> := Packet} when map_size(Payload) =:= 3 ->
            Target = case Type of <<"membership">> -> ba_buffee_membership;<<"buffee_control">> -> ba_buffee_control;_ -> undefined end,
            case Target =/= undefined andalso is_binary(Packet) andalso byte_size(Packet) =< 32768 of
                true -> notify(Target,{desk_delivery,URL,From,Packet});
                false -> {error,invalid_desk_payload}
            end;
        _ -> {error,invalid_desk_payload}
    end,
    Next = case Delivery of {error,R} -> ba_diagnostics:count(R,S);_ -> S end,
    {noreply,Next}.
