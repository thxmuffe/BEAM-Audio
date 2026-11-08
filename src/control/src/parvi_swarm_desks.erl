%% A bounded set of independent Desk connections; no membership authority here.
-module(parvi_swarm_desks).
-behaviour(gen_server).
-export([start_link/0,configure/4,route/0,send/3,send_route/4,status/0]).
-export([init/1,handle_call/3,handle_cast/2,handle_info/2,terminate/2,format_status/1]).
start_link() -> gen_server:start_link({local,?MODULE},?MODULE,[],[]).
configure(Swarm,URLs,Primary,Routes) -> gen_server:call(?MODULE,{configure,Swarm,URLs,Primary,Routes}).
route() -> gen_server:call(?MODULE,route).
send(To,Type,Packet) -> gen_server:call(?MODULE,{send,To,Type,Packet},3000).
send_route(To,Route,Type,Packet) -> gen_server:call(?MODULE,{send_route,To,Route,Type,Packet},3000).
status() -> gen_server:call(?MODULE,status).
init([]) ->
    true = os:getenv("PARVI_IDENTITY_SEED") =/= false,
    true = os:getenv("PARVI_STATE_DIR") =/= false,
    process_flag(trap_exit,true),
    {Public,_} = parvi_cluster_store:identity(),Id = binary:encode_hex(Public),
    Saved = parvi_cluster_store:load(swarm_desks,#{id => Id,mailbox => fresh()}),
    Id = maps:get(id,Saved),ok = parvi_cluster_store:save(swarm_desks,Saved),
    {ok,#{id => Id,mailbox => maps:get(mailbox,Saved),swarm => undefined,primary => undefined,
          relays => #{},routes => #{},rejected => 0}}.
handle_call(route,_,S) -> {reply,#{<<"desk">> => maps:get(primary,S),<<"mailbox">> => maps:get(mailbox,S)},S};
handle_call(status,_,S) ->
    Views = maps:map(fun(_,P) -> gen_server:call(P,status) end,maps:get(relays,S)),
    {reply,#{id => maps:get(id,S),desks => Views,rejected => maps:get(rejected,S)},S};
handle_call({configure,Swarm,URLs,Primary,Routes},_,S) ->
    true = parvi_swarm_job:hex(Swarm,32),
    true = is_list(URLs) andalso length(URLs) > 0 andalso length(URLs) =< 4,
    true = length(lists:usort(URLs)) =:= length(URLs),
    true = lists:member(Primary,URLs),
    true = lists:all(fun parvi_relay:valid_url/1,URLs),
    true = is_map(Routes) andalso map_size(Routes) =< 16,
    maps:foreach(fun(Id,R) -> true = parvi_swarm_job:hex(Id,64),valid_route(R,URLs) end,Routes),
    Old = maps:get(relays,S),
    maps:foreach(fun(URL,P) ->
        case lists:member(URL,URLs) of true -> ok;false -> gen_server:stop(P) end
    end,Old),
    Relays = maps:from_list([{URL,case maps:find(URL,Old) of
        {ok,P} -> P;
        error ->
            {ok,P} = parvi_relay:start_link(#{owner => self(),delivery => raw,register => false,
                identity => parvi_cluster_store:identity(),url => URL,tag => URL,max_owner_queue => 64}),P
    end} || URL <- URLs]),
    maps:foreach(fun(_,P) ->
        gen_server:cast(P,{open,Swarm,maps:get(mailbox,S)}),
        gen_server:cast(P,{watch,maps:keys(Routes)})
    end,Relays),
    {reply,ok,S#{swarm := Swarm,primary := Primary,relays := Relays,routes := Routes}};
handle_call({send,To,Type,Packet},From,S) ->
    case maps:find(To,maps:get(routes,S)) of
        {ok,R} -> handle_call({send_route,To,R,Type,Packet},From,S);
        error -> {reply,{error,no_route},S}
    end;
handle_call({send_route,To,Route,Type,Packet},_,S) ->
    Result = try
        true = parvi_swarm_job:hex(To,64),
        true = is_binary(Packet) andalso byte_size(Packet) =< 32768,
        true = Type =:= <<"membership">> orelse Type =:= <<"swarm_control">>,
        valid_route(Route,maps:keys(maps:get(relays,S))),
        Pid = maps:get(maps:get(<<"desk">>,Route),maps:get(relays,S)),
        gen_server:call(Pid,{send,To,maps:get(<<"mailbox">>,Route),
            #{<<"type">> => Type,<<"swarm">> => maps:get(swarm,S),<<"packet">> => Packet}},2000)
    catch _:_ -> {error,unavailable} end,
    {reply,Result,S};
handle_call(_,_,S) -> {reply,{error,unsupported},S}.
handle_cast(_,S) -> {noreply,S}.
handle_info({relay,URL,{delivery,From,Cap,Payload}},#{mailbox := Cap,swarm := Swarm} = S) ->
    case Payload of
        #{<<"type">> := Type,<<"swarm">> := Swarm,<<"packet">> := Packet} when map_size(Payload) =:= 3 ->
            Target = case Type of <<"membership">> -> parvi_swarm_membership;<<"swarm_control">> -> parvi_swarm_control;_ -> undefined end,
            case Target =/= undefined andalso is_binary(Packet) andalso byte_size(Packet) =< 32768 of
                true -> notify(Target,{desk_delivery,URL,From,Packet});
                false -> ok
            end;
        _ -> ok
    end,{noreply,S};
handle_info({relay,URL,Event},S) ->
    notify(parvi_swarm_membership,{desk_event,URL,Event}),
    notify(parvi_swarm_control,{desk_event,URL,Event}),{noreply,S};
handle_info({'EXIT',Pid,Reason},S) ->
    case lists:member(Pid,maps:values(maps:get(relays,S))) of
        true -> {stop,{desk_stopped,Reason},S};false -> {noreply,S}
    end;
handle_info(_,S) -> {noreply,S}.
valid_route(#{<<"desk">> := URL,<<"mailbox">> := Cap} = R,URLs) ->
    true = map_size(R) =:= 2,true = lists:member(URL,URLs),true = parvi_swarm_job:hex(Cap,32),ok.
notify(Name,Event) ->
    case whereis(Name) of
        undefined -> ok;
        Pid -> case process_info(Pid,message_queue_len) of
            {message_queue_len,N} when N < 64 -> Pid ! Event;
            _ -> ok
        end
    end.
fresh() -> binary:encode_hex(crypto:strong_rand_bytes(16)).
terminate(_,S) -> maps:foreach(fun(_,P) -> try gen_server:stop(P) catch _:_ -> ok end end,maps:get(relays,S)),ok.
format_status(Status) -> maps:map(fun(state,S) -> maps:with([id,swarm,primary],S);(log,_) -> [];(_,_) -> redacted end,Status).
