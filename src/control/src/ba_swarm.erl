%% One voluntary, temporary gathering per runtime. Reusable links are addresses,
%% never restored authority, membership, grants or live operation state.
-module(ba_swarm).
-behaviour(gen_server).
-export([start_link/0,create/2,join/1,start/1,status/0,connection/0,disconnect/0,remember/3,leave/0,end_swarm/0,invite/2,ended/1]).
-export([init/1,handle_call/3,handle_cast/2,handle_info/2,format_status/1]).
start_link() -> gen_server:start_link({local,?MODULE},?MODULE,[],[]).
create(Name,Desks) -> start(#{mode => create,name => Name,desks => Desks}).
join(Link) -> start(#{mode => join,invitation => Link}).
start(Config) -> gen_server:call(?MODULE,{start,Config},15000).
status() -> gen_server:call(?MODULE,status).
connection() -> gen_server:call(?MODULE,connection).
disconnect() -> gen_server:call(?MODULE,disconnect,15000).
remember(Pid,Name,Member) -> gen_server:cast(?MODULE,{remember,Pid,Name,Member}).
leave() -> gen_server:call(?MODULE,leave,15000).
end_swarm() -> gen_server:call(?MODULE,end_swarm,15000).
invite(Selection,TTL) -> gen_server:call(?MODULE,{invite,Selection,TTL}).
ended(Membership) -> gen_server:cast(?MODULE,{ended,Membership}).
init([]) ->
    %% Load the record schema's atoms before binary_to_term(...,[safe]).
    {module,ba_swarm_membership}=code:ensure_loaded(ba_swarm_membership),
    Saved=ba_device_store:load(swarm_connection,undefined),
    self() ! cleanup,
    {ok,#{state => idle,remembered => Saved,connection_state => idle}}.
handle_call(status,_,#{state := idle}=S) -> {reply,#{state => idle},S};
handle_call(status,_,S) ->
    View = membership_status(),
    {reply,View,S};
handle_call(connection,_,S) -> {reply,connection_view(S),S};
handle_call({start,Config},_,#{state := idle}=S) ->
    case valid(Config) of
        false -> {reply,{error,invalid_swarm_config},S};
        true ->
            Saved=description(Config),
            ok=ba_device_store:save(swarm_connection,Saved),
            {Result,Next}=activate(Config,S#{remembered := Saved}),
            {reply,Result,Next}
    end;
handle_call({start,_},_,S) -> {reply,{error,already_in_swarm},S};
handle_call({invite,Selection,TTL},_,#{state := active}=S) ->
    Result = case ba_contacts:resolve(Selection) of
        {ok,Ids} -> ba_swarm_membership:invite_devices(Ids,TTL);
        Error -> Error
    end,{reply,Result,S};
handle_call(end_swarm,_,#{state := active}=S) ->
    case ba_swarm_membership:status() of
        #{role := authority} -> ba_swarm_membership:depart(),{reply,ok,forget(stop(S))};
        _ -> {reply,{error,captain_only},S}
    end;
handle_call(leave,_,S) ->
    case maps:get(state,S) of active -> ba_swarm_membership:depart();idle -> ok end,
    {reply,ok,forget(stop(S))};
handle_call(disconnect,_,S) ->
    %% Closing a participant app is transport loss, not voluntary membership removal.
    case maps:get(state,S) of
        active -> case ba_swarm_membership:status() of
            #{role := authority} -> ba_swarm_membership:depart();_ -> ok end;
        idle -> ok
    end,
    {reply,ok,stop(S)};
handle_call(_,_,S) -> {reply,{error,no_active_swarm},S}.
handle_cast({peer_name,Peer,Name},#{remembered := Saved}=S) when is_map(Saved),is_binary(Name) ->
    case captain_id(Saved)=:=Peer andalso maps:get(captain_name,Saved,undefined)=/=Name of
        true -> Next=Saved#{captain_name => Name},ok=ba_device_store:save(swarm_connection,Next),
            {noreply,S#{remembered := Next}};
        false -> {noreply,S}
    end;
handle_cast({ended,Membership},#{membership := Membership}=S) -> {noreply,stop(S)};
handle_cast({remember,Membership,Name,Member},#{membership := Membership}=S) ->
    Saved=#{name => Name,swarm => maps:get(swarm,Member),
        config => #{mode => rejoin,name => Name,member => Member}},
    Previous=maps:get(remembered,S,undefined),
    Named=case is_map(Previous) andalso captain_id(Previous)=:=captain_id(Saved) of
        true -> maps:merge(maps:with([captain_name],Previous),Saved);
        false -> Saved
    end,
    ok=ba_device_store:save(swarm_connection,Named),
    {noreply,S#{remembered := Named}};
handle_cast(_,S) -> {noreply,S}.
handle_info(cleanup,S) ->
    %% A lifecycle-owner crash ends its old gathering rather than restoring it.
    application:unset_env(ba_core,swarm_membership),
    Next=stop(S),
    case application:get_env(ba_core,restore_swarm_on_start,false) of
        true -> self() ! restore;
        false -> ok
    end,
    {noreply,Next};
handle_info(restore,#{state := idle,remembered := #{config := Config}}=S) ->
    case maps:get(mode,Config) of
        create -> {noreply,S#{connection_state := ended}};
        _ -> case valid(Config) of
            true -> {_,Next}=activate(Config,S),{noreply,Next};
            false -> {noreply,S#{connection_state := failed}}
        end
    end;
handle_info({'DOWN',Ref,process,_,_},#{monitor := Ref}=S) -> {noreply,stop(S)};
handle_info(_,S) -> {noreply,S}.
stop(S) ->
    case maps:find(monitor,S) of {ok,Ref} -> demonitor(Ref,[flush]);error -> ok end,
    supervisor:terminate_child(ba_sup,ba_swarm_runtime_sup),
    supervisor:delete_child(ba_sup,ba_swarm_runtime_sup),
    ba_swarm_desks:reset(),(maps:with([remembered],S))#{state => idle,connection_state => unavailable}.
activate(Config,S) ->
    application:set_env(ba_core,swarm_membership,Config),
    Result=supervisor:start_child(ba_sup,#{id => ba_swarm_runtime_sup,
        start => {ba_swarm_runtime_sup,start_link,[]},restart => temporary,
        type => supervisor,shutdown => infinity}),
    application:unset_env(ba_core,swarm_membership),
    case Result of
        {ok,Pid} -> {ok,S#{state := active,pid => Pid,monitor => monitor(process,Pid),
            membership => whereis(ba_swarm_membership),connection_state := rejoining}};
        {error,_} -> ba_swarm_desks:reset(),
            {{error,swarm_start_failed},S#{connection_state := failed}}
    end.
forget(S) -> ok=ba_device_store:save(swarm_connection,undefined),
    S#{remembered := undefined,connection_state := idle}.
description(#{mode := rejoin,name := Name,member := Member}=C) ->
    #{name => Name,swarm => maps:get(swarm,Member),config => C};
description(#{mode := create,name := Name}=C) -> #{name => Name,config => C};
description(#{mode := join,invitation := Link}=C) ->
    {_,I}=ba_swarm_passport:parse_invitation(Link),
    #{name => maps:get(<<"name">>,I),swarm => maps:get(<<"swarm">>,I),config => C}.
connection_view(#{remembered := undefined}) -> #{state => idle};
connection_view(#{remembered := Saved}=S) ->
    State=case maps:get(state,S) of
        active -> case membership_status() of
            #{state := ended} -> unavailable;
            #{state := ending} -> unavailable;
            #{state := authorized} -> joined;
            #{state := revoked} -> revoked;
            _ -> rejoining
        end;
        idle -> maps:get(connection_state,S)
    end,
    Captain=captain_id(Saved),
    Label=maps:get(captain_name,Saved,captain_fallback(Captain)),
    Message=case State of
        joined -> <<"Connected">>;
        rejoining -> <<"Rejoining Swarm — waiting for Desk and ",Label/binary,"…"/utf8>>;
        ended -> <<"This Device hosted the previous Swarm. That gathering ended when it stopped.">>;
        unavailable -> <<"Could not reconnect to ",Label/binary,". That Device is unavailable or the Swarm has ended.">>;
        revoked -> <<"Admission denied. This Device may have been removed from the Swarm.">>;
        failed -> <<"Could not restore the saved connection. Paste its invitation to join or start a fresh gathering.">>;
        idle -> <<"Previous Swarm remembered">>
    end,
    (maps:with([name,swarm],Saved))#{state => State,message => Message,captain => Captain,captain_name => Label}.
captain_id(#{config := #{member := #{authority := Id}}}) -> Id;
captain_id(#{config := #{invitation := Link}}) ->
    try {_,I}=ba_swarm_passport:parse_invitation(Link),maps:get(<<"authority">>,I) catch _:_ -> <<>> end;
captain_id(_) -> <<>>.
captain_fallback(<<>>) -> <<"the hosting Device">>;
captain_fallback(Id) -> <<"Device ",(binary:part(Id,0,min(12,byte_size(Id))))/binary>>.
membership_status() ->
    try ba_swarm_membership:status() catch exit:_ -> #{state => ending} end.
valid(#{mode := create,name := Name,desks := Desks}) ->
    try true = is_binary(Name) andalso byte_size(Name)>0 andalso byte_size(Name)=<128,
        true = is_list(unicode:characters_to_list(Name)),ok = ba_swarm_passport:urls(Desks),true
    catch _:_ -> false end;
valid(#{mode := join,invitation := Link}) ->
    try ba_swarm_passport:parse_invitation(Link),true catch _:_ -> false end;
valid(#{mode := rejoin,name := Name,member := #{id := Id,passport := Passport,authority := Authority,swarm := Swarm}}) ->
    try true=is_binary(Name),{Public,_}=ba_device_store:identity(),Id=binary:encode_hex(Public),
        ba_swarm_passport:passport(Passport,Authority,Id,Swarm),true catch _:_ -> false end;
valid(_) -> false.
format_status(Status) -> maps:map(fun(state,S) -> maps:with([state],S);(log,_) -> [];(_,_) -> redacted end,Status).
