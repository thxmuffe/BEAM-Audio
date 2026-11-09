%% One voluntary, temporary gathering per local runtime; no resurrection/election.
-module(ba_swarm).
-behaviour(gen_server).
-export([start_link/0,create/2,join/1,start/1,status/0,leave/0,end_swarm/0,invite/2,ended/1]).
-export([init/1,handle_call/3,handle_cast/2,handle_info/2,format_status/1]).
start_link() -> gen_server:start_link({local,?MODULE},?MODULE,[],[]).
create(Name,Desks) -> start(#{mode => create,name => Name,desks => Desks}).
join(Link) -> start(#{mode => join,invitation => Link}).
start(Config) -> gen_server:call(?MODULE,{start,Config},15000).
status() -> gen_server:call(?MODULE,status).
leave() -> gen_server:call(?MODULE,leave,15000).
end_swarm() -> gen_server:call(?MODULE,end_swarm,15000).
invite(Selection,TTL) -> gen_server:call(?MODULE,{invite,Selection,TTL}).
ended(Membership) -> gen_server:cast(?MODULE,{ended,Membership}).
init([]) -> self() ! cleanup,{ok,#{state => idle}}.
handle_call(status,_,#{state := idle}=S) -> {reply,#{state => idle},S};
handle_call(status,_,S) ->
    View = try ba_swarm_membership:status() catch exit:_ -> #{state => ending} end,
    {reply,View,S};
handle_call({start,Config},_,#{state := idle}=S) ->
    case valid(Config) of
        false -> {reply,{error,invalid_swarm_config},S};
        true ->
            application:set_env(ba_core,swarm_membership,Config),
            Result = supervisor:start_child(ba_sup,#{id => ba_swarm_runtime_sup,
                start => {ba_swarm_runtime_sup,start_link,[]},restart => temporary,
                type => supervisor,shutdown => infinity}),
            application:unset_env(ba_core,swarm_membership),
            case Result of
                {ok,Pid} -> Ref = monitor(process,Pid),
                    {reply,ok,#{state => active,pid => Pid,monitor => Ref,membership => whereis(ba_swarm_membership)}};
                {error,_} -> ba_swarm_desks:reset(),{reply,{error,swarm_start_failed},S}
            end
    end;
handle_call({start,_},_,S) -> {reply,{error,already_in_swarm},S};
handle_call({invite,Selection,TTL},_,#{state := active}=S) ->
    Result = case ba_contacts:resolve(Selection) of
        {ok,Ids} -> ba_swarm_membership:invite_devices(Ids,TTL);
        Error -> Error
    end,{reply,Result,S};
handle_call(end_swarm,_,#{state := active}=S) ->
    case ba_swarm_membership:status() of
        #{role := authority} -> ba_swarm_membership:depart(),{reply,ok,stop(S)};
        _ -> {reply,{error,captain_only},S}
    end;
handle_call(leave,_,S) ->
    case maps:get(state,S) of active -> ba_swarm_membership:depart();idle -> ok end,
    {reply,ok,stop(S)};
handle_call(_,_,S) -> {reply,{error,no_active_swarm},S}.
handle_cast({ended,Membership},#{membership := Membership}=S) -> {noreply,stop(S)};
handle_cast(_,S) -> {noreply,S}.
handle_info(cleanup,S) ->
    %% A lifecycle-owner crash ends its old gathering rather than restoring it.
    application:unset_env(ba_core,swarm_membership),{noreply,stop(S)};
handle_info({'DOWN',Ref,process,_,_},#{monitor := Ref}=S) -> {noreply,stop(S)};
handle_info(_,S) -> {noreply,S}.
stop(S) ->
    case maps:find(monitor,S) of {ok,Ref} -> demonitor(Ref,[flush]);error -> ok end,
    supervisor:terminate_child(ba_sup,ba_swarm_runtime_sup),
    supervisor:delete_child(ba_sup,ba_swarm_runtime_sup),
    ba_swarm_desks:reset(),#{state => idle}.
valid(#{mode := create,name := Name,desks := Desks}) ->
    try true = is_binary(Name) andalso byte_size(Name)>0 andalso byte_size(Name)=<128,
        true = is_list(unicode:characters_to_list(Name)),ok = ba_swarm_passport:urls(Desks),true
    catch _:_ -> false end;
valid(#{mode := join,invitation := Link}) ->
    try ba_swarm_passport:parse_invitation(Link),true catch _:_ -> false end;
valid(_) -> false.
format_status(Status) -> maps:map(fun(state,S) -> maps:with([state],S);(log,_) -> [];(_,_) -> redacted end,Status).
