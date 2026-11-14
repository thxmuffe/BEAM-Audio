%% One active Buffee per local Session scope. Ownership survives leaving or app shutdown.
-module(ba_buffee).
-behaviour(gen_server).
-export([start_link/0,create/2,join/1,start/1,status/0,connection/0,disconnect/0,remember/3,remember_authority/2,leave/0,end_buffee/0,invite/2,ended/1,broadcast/0,broadcast/1,broadcast_token/0]).
-export([init/1,handle_call/3,handle_cast/2,handle_info/2,format_status/1]).
start_link() -> gen_server:start_link(ba_session_scope:registration(?MODULE),?MODULE,[],[]).
create(Name,Desks) ->
    Config=#{mode => create,name => Name,desks => Desks},
    start(case ba_session_scope:current() of undefined -> Config;Id -> Config#{buffee => Id} end).
join(Link) -> start(#{mode => join,invitation => Link}).
start(Config) -> gen_server:call(ba_session_scope:ref(?MODULE),{start,Config},15000).
broadcast_token() -> gen_server:call(ba_session_scope:ref(?MODULE),broadcast_token).
broadcast() -> gen_server:call(ba_session_scope:ref(?MODULE),broadcast).
broadcast(B) when is_boolean(B) -> gen_server:call(ba_session_scope:ref(?MODULE),{broadcast,B}).
status() -> gen_server:call(ba_session_scope:ref(?MODULE),status).
connection() -> gen_server:call(ba_session_scope:ref(?MODULE),connection).
disconnect() -> gen_server:call(ba_session_scope:ref(?MODULE),disconnect,15000).
remember_authority(Pid,Saved) -> gen_server:cast(ba_session_scope:ref(?MODULE),{remember_authority,Pid,Saved}).
remember(Pid,Name,Member) -> gen_server:cast(ba_session_scope:ref(?MODULE),{remember,Pid,Name,Member}).
leave() -> gen_server:call(ba_session_scope:ref(?MODULE),leave,15000).
end_buffee() -> gen_server:call(ba_session_scope:ref(?MODULE),end_buffee,15000).
invite(Selection,TTL) -> gen_server:call(ba_session_scope:ref(?MODULE),{invite,Selection,TTL}).
ended(Membership) -> gen_server:cast(ba_session_scope:ref(?MODULE),{ended,Membership}).
init([]) ->
    %% Load the record schema's atoms before binary_to_term(...,[safe]).
    {module,ba_buffee_membership}=code:ensure_loaded(ba_buffee_membership),
    Saved=ba_device_store:load(buffee_connection,undefined),
    self() ! cleanup,
    {ok,#{state => idle,remembered => Saved,connection_state => idle}}.
handle_call(broadcast_token,_,S) -> {reply,case maps:get(broadcast,S,false) of true -> {ok,maps:get(broadcast_token,S)};false -> {error,consent_required} end,S};
handle_call(broadcast,_,S) -> {reply,maps:get(broadcast,S,false),S};
handle_call({broadcast,B},_,S) ->
    case ba_session_scope:whereis(ba_device_handler) of undefined -> ok;_ -> ba_device_handler:audio_changed() end,
    {reply,ok,S#{broadcast => B,broadcast_token => make_ref()}};
handle_call(status,_,#{state := idle}=S) -> {reply,#{state => idle},S};
handle_call(status,_,S) ->
    View = membership_status(),
    {reply,View,S};
handle_call(connection,_,S) -> {reply,connection_view(S),S};
handle_call({start,Input},_,#{state := idle}=S) ->
    Config=rejoin_config(Input,maps:get(remembered,S,undefined)),
    case valid(Config) of
        false -> {reply,{error,invalid_buffee_config},S};
        true ->
            Saved=description(Config),
            ok=ba_device_store:save(buffee_connection,Saved),
            {Result,Next}=activate(Config,S#{remembered := Saved}),
            {reply,Result,Next}
    end;
handle_call({start,_},_,S) -> {reply,{error,already_in_buffee},S};
handle_call({invite,Selection,TTL},_,#{state := active}=S) ->
    Result = case ba_contacts:resolve(Selection) of
        {ok,Ids} -> ba_buffee_membership:invite_devices(Ids,TTL);
        Error -> Error
    end,{reply,Result,S};
handle_call(end_buffee,_,#{state := active}=S) ->
    case ba_buffee_membership:status() of
        #{role := owner} -> ba_buffee_membership:depart(),{reply,ok,forget(stop(S))};
        _ -> {reply,{error,owner_only},S}
    end;
handle_call(leave,_,#{state := active}=S) ->
    case ba_buffee_membership:status() of
        #{role := owner} -> {reply,ok,stop(S)};
        _ -> ba_buffee_membership:depart(),{reply,ok,forget(stop(S))}
    end;
handle_call(leave,_,#{remembered := #{config := #{mode := recover_authority}}}=S) ->
    {reply,ok,stop(S)};
handle_call(leave,_,S) -> {reply,ok,forget(stop(S))};
handle_call(disconnect,_,S) ->
    %% App/transport closure is not an End Buffee command, including the Owner.
    {reply,ok,stop(S)};
handle_call(_,_,S) -> {reply,{error,no_active_buffee},S}.
handle_cast({remember_authority,Membership,Saved},#{membership := Membership}=S) ->
    %% The membership owner persisted this before publishing its policy.
    {noreply,S#{remembered := Saved}};
handle_cast({peer_name,Peer,Name},#{remembered := Saved}=S) when is_map(Saved),is_binary(Name) ->
    case owner_id(Saved)=:=Peer andalso maps:get(owner_name,Saved,undefined)=/=Name of
        true -> Next=Saved#{owner_name => Name},ok=ba_device_store:save(buffee_connection,Next),
            {noreply,S#{remembered := Next}};
        false -> {noreply,S}
    end;
handle_cast({ended,Membership},#{membership := Membership}=S) -> {noreply,forget(stop(S))};
handle_cast({remember,Membership,Name,Member},#{membership := Membership}=S) ->
    Saved=#{name => Name,buffee => maps:get(buffee,Member),
        config => #{mode => rejoin,name => Name,member => Member}},
    Previous=maps:get(remembered,S,undefined),
    Named=case is_map(Previous) andalso owner_id(Previous)=:=owner_id(Saved) of
        true -> maps:merge(maps:with([owner_name],Previous),Saved);
        false -> Saved
    end,
    ok=ba_device_store:save(buffee_connection,Named),
    {noreply,S#{remembered := Named}};
handle_cast(_,S) -> {noreply,S}.
handle_info(cleanup,S) ->
    %% Recreate local workers before restoring saved participation or ownership.
    ba_session_scope:unset_env(buffee_membership),
    Next=stop(S),
    case restore_enabled() of
        true -> self() ! restore;
        false -> ok
    end,
    {noreply,Next};
handle_info(restore,#{state := idle,remembered := #{config := Config}}=S) ->
    case maps:get(mode,Config) of
        create -> {noreply,S#{connection_state := failed}};
        _ -> case valid(Config) of
            true -> {_,Next}=activate(Config,S),{noreply,Next};
            false -> {noreply,S#{connection_state := failed}}
        end
    end;
handle_info({'DOWN',Ref,process,_,_},#{monitor := Ref}=S) -> {noreply,stop(S)};
handle_info(_,S) -> {noreply,S}.
stop(S) ->
    case maps:find(monitor,S) of {ok,Ref} -> demonitor(Ref,[flush]);error -> ok end,
    supervisor:terminate_child(ba_session_scope:ref(ba_sup),ba_buffee_runtime_sup),
    supervisor:delete_child(ba_session_scope:ref(ba_sup),ba_buffee_runtime_sup),
    ba_buffee_desks:reset(),(maps:with([remembered],S))#{state => idle,connection_state => unavailable}.
activate(Config,S) ->
    ba_session_scope:set_env(buffee_membership,Config),
    Result=supervisor:start_child(ba_session_scope:ref(ba_sup),#{id => ba_buffee_runtime_sup,
        start => {ba_buffee_runtime_sup,start_link,[]},restart => temporary,
        type => supervisor,shutdown => infinity}),
    ba_session_scope:unset_env(buffee_membership),
    case Result of
        {ok,Pid} -> {ok,S#{state := active,pid => Pid,monitor => monitor(process,Pid),
            membership => ba_session_scope:whereis(ba_buffee_membership),connection_state := rejoining}};
        {error,_} -> ba_buffee_desks:reset(),
            {{error,buffee_start_failed},S#{connection_state := failed}}
    end.
forget(S) -> ok=ba_device_store:save(buffee_connection,undefined),
    S#{remembered := undefined,connection_state := idle}.
description(#{mode := recover_authority,snapshot := #{name := Name,policy := P}}=C) ->
    #{name => Name,buffee => maps:get(<<"buffee">>,P),config => C};
description(#{mode := rejoin,name := Name,member := Member}=C) ->
    #{name => Name,buffee => maps:get(buffee,Member),config => C};
description(#{mode := create,name := Name}=C) -> #{name => Name,config => C};
description(#{mode := join,invitation := Link}=C) ->
    {_,I}=ba_buffee_passport:parse_invitation(Link),
    #{name => maps:get(<<"name">>,I),buffee => maps:get(<<"buffee">>,I),config => C}.
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
    Owner=owner_id(Saved),
    Label=maps:get(owner_name,Saved,owner_fallback(Owner)),
    Message=case State of
        joined -> <<"Connected">>;
        rejoining -> <<"Rejoining Session — waiting for Reception and ",Label/binary,"…"/utf8>>;
        unavailable -> <<"Could not reconnect to ",Label/binary,". That Device is unavailable or the Session has ended.">>;
        revoked -> <<"Admission denied. This Device may have been removed from the Session.">>;
        failed -> <<"Could not restore the saved connection. Paste its invitation to join or start a fresh gathering.">>;
        idle -> <<"Previous Session remembered">>
    end,
    (maps:with([name,buffee],Saved))#{state => State,message => Message,owner => Owner,owner_name => Label}.
owner_id(#{config := #{member := #{authority := Id}}}) -> Id;
owner_id(#{config := #{invitation := Link}}) ->
    try {_,I}=ba_buffee_passport:parse_invitation(Link),maps:get(<<"authority">>,I) catch _:_ -> <<>> end;
owner_id(_) -> <<>>.
owner_fallback(<<>>) -> <<"the hosting Device">>;
owner_fallback(Id) -> <<"Device ",(binary:part(Id,0,min(12,byte_size(Id))))/binary>>.
membership_status() ->
    try ba_buffee_membership:status() catch exit:_ -> #{state => ending} end.
valid(#{mode := recover_authority,snapshot := #{policy := Policy,urls := URLs,name := Name}}) ->
    try
        ok=ba_buffee_passport:policy(Policy),ok=ba_buffee_passport:urls(URLs),
        {Public,_}=ba_device_store:identity(),true=ba_buffee_roles:owner(binary:encode_hex(Public),Policy),
        true=is_binary(Name) andalso byte_size(Name)>0 andalso byte_size(Name)=<128,true
    catch _:_ -> false end;
valid(#{mode := create,name := Name,desks := Desks}) ->
    try true = is_binary(Name) andalso byte_size(Name)>0 andalso byte_size(Name)=<128,
        true = is_list(unicode:characters_to_list(Name)),ok = ba_buffee_passport:urls(Desks),true
    catch _:_ -> false end;
valid(#{mode := join,invitation := Link}) ->
    try ba_buffee_passport:parse_invitation(Link),true catch _:_ -> false end;
valid(#{mode := rejoin,name := Name,member := #{id := Id,passport := Passport,authority := Authority,buffee := Buffee}}) ->
    try true=is_binary(Name),{Public,_}=ba_device_store:identity(),Id=binary:encode_hex(Public),
        true = ba_buffee_job:hex(Authority,64),
        Envelope=ba_buffee_passport:decode(Passport),Body=ba_buffee_passport:decode(base64:decode(maps:get(<<"body">>,Envelope))),
        ba_buffee_passport:passport(Passport,maps:get(<<"authority">>,Body),Id,Buffee),true catch _:_ -> false end;
valid(_) -> false.
format_status(Status) -> maps:map(fun(state,S) -> maps:with([state],S);(log,_) -> [];(_,_) -> redacted end,Status).

rejoin_config(#{mode := join,invitation := Link}=Config,
              #{buffee := Id,config := #{mode := recover_authority}=Recovery}) ->
    try
        {_,Invitation}=ba_buffee_passport:parse_invitation(Link),
        case maps:get(<<"buffee">>,Invitation)=:=Id of true -> Recovery;false -> Config end
    catch _:_ -> Config end;
rejoin_config(Config,_) -> Config.

restore_enabled() ->
    ba_session_scope:get_env(restore_buffee_on_start,false) andalso
    (ba_session_scope:current()=/=undefined orelse lists:any(fun(D) -> maps:get(id,D)=:=<<"default">> end,
        ba_device_store:load(web_sessions,[#{id => <<"default">>}]))).
