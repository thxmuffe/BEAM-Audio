%% Device-owned Session tabs. Each Session has local OTP workers and saved state;
%% identity, address book and authenticated Reception connections are shared.
-module(ba_sessions).
-behaviour(gen_server).
-export([start_link/0,request/1]).
-export([init/1,handle_call/3,handle_cast/2,handle_info/2]).
start_link() -> gen_server:start_link({local,?MODULE},?MODULE,[],[]).
request(Command) -> gen_server:call(?MODULE,{request,Command},30000).
init([]) ->
    Tabs=ba_device_store:load(web_sessions,[#{id => <<"default">>,name => <<"Session">>,buffee => null}]),
    self() ! restore,{ok,#{tabs => Tabs}}.
handle_info(restore,#{tabs := Tabs}=S) ->
    [start(Id) || #{id := Id} <- Tabs,Id=/=<<"default">>],{noreply,S};
handle_info(_,S) -> {noreply,S}.
handle_cast(_,S) -> {noreply,S}.
handle_call({request,#{<<"method">> := <<"list_sessions">>}=Command},_,S) ->
    {reply,metadata(null,#{},S,Command),S};
handle_call({request,#{<<"method">> := <<"new_session">>}=Command},_,#{tabs := Tabs}=S) ->
    Id=binary:encode_hex(crypto:strong_rand_bytes(16)),
    case start(Id) of
        ok -> Next=save(S#{tabs := Tabs++[#{id => Id,name => <<"New Session">>,buffee => null}]}),
              {reply,metadata(Id,#{},Next,Command),Next};
        {error,_} -> {reply,metadata(null,#{<<"error">> => <<"Could not start Session.">>},S,Command),S}
    end;
handle_call({request,#{<<"method">> := <<"close_session">>,<<"session">> := Id}=Command},_,#{tabs := Tabs}=S) ->
    case lists:any(fun(D) -> maps:get(id,D)=:=Id end,Tabs) of
        false -> {reply,metadata(null,#{<<"error">> => <<"Unknown Session.">>},S,Command),S};
        true ->
            _=in(Id,fun ba_buffee:leave/0),stop(Id),
            Next=save(S#{tabs := [D || D <- Tabs,maps:get(id,D)=/=Id]}),
            {reply,metadata(null,#{},Next,Command),Next}
    end;
handle_call({request,Command},From,#{tabs := Tabs}=S) ->
    Default=case Tabs of [#{id := I}|_] -> I;[] -> null end,
    Id=maps:get(<<"session">>,Command,Default),
    case lists:any(fun(D) -> maps:get(id,D)=:=Id end,Tabs) of
        false -> {reply,metadata(null,#{<<"error">> => <<"No open Session.">>},S,Command),S};
        true ->
            case prepare(Id,Command,S) of
                {error,Message} -> {reply,metadata(Id,#{<<"error">> => Message},S,Command),S};
                {Selected,Next} ->
                    spawn(fun() ->
                        Reply=try in(Selected,fun() -> dispatch(Command) end)
                            catch _:_ -> #{<<"error">> => <<"Session unavailable.">>} end,
                        Result=gen_server:call(?MODULE,{finished,Selected,Reply,Command},10000),
                        gen_server:reply(From,Result)
                    end),
                    {noreply,Next}
            end
    end;
handle_call({finished,Id,Reply,Command},_,#{tabs := Tabs}=S) ->
    Next=case maps:get(buffee,Reply,undefined) of
        #{state := idle} -> save_changed(S,S#{tabs := [case maps:get(id,D)=:=Id of true -> D#{name := <<"New Session">>,buffee := null};false -> D end || D <- Tabs]});
        #{name := Name,buffee := Buffee} -> save_changed(S,S#{tabs := [case maps:get(id,D)=:=Id of true -> D#{name := Name,buffee := Buffee};false -> D end || D <- Tabs]});
        _ -> S
    end,
    {reply,metadata(Id,Reply,Next,Command),Next};
handle_call(_,_,S) -> {reply,{error,unsupported},S}.
in(<<"default">>,F) -> ba_session_scope:run(undefined,F);
in(Id,F) -> ba_session_scope:run(Id,F).
start(Id) ->
    Spec=#{id => {session,Id},start => {ba_session_sup,start_link,[Id]},type => supervisor,shutdown => infinity},
    case supervisor:start_child(ba_sup,Spec) of
        {ok,_} -> ok;{error,{already_started,_}} -> ok;Error -> Error
    end.
stop(<<"default">>) -> ok;
stop(Id) -> supervisor:terminate_child(ba_sup,{session,Id}),supervisor:delete_child(ba_sup,{session,Id}),ba_session_scope:clear(Id).
save_changed(#{tabs := Tabs},#{tabs := Tabs}=S) -> S;
save_changed(_,S) -> save(S).
save(#{tabs := Tabs}=S) -> ok=ba_device_store:save(web_sessions,Tabs),S.
metadata(Id,Reply,#{tabs := Tabs},Command) ->
    Base=#{<<"error">> => null,session_id => Id,sessions => Tabs,supports_sessions => true},
    maps:merge(maps:merge(Base,Reply),maps:with([<<"request_id">>],Command)).
prepare(Id,#{<<"method">> := <<"join_buffee">>,<<"invitation">> := Link},#{tabs := Tabs}=S) ->
    try
        {_,I}=ba_buffee_passport:parse_invitation(Link),Target=maps:get(<<"buffee">>,I),
        Existing=[maps:get(id,D) || D <- Tabs,maps:get(buffee,D,null)=:=Target],
        case Existing of
            [Selected|_] ->
                case Id=:=Selected of true -> {Id,S};false ->
                    case blank(Id,Tabs) of true -> stop(Id),{Selected,save(S#{tabs := [D || D <- Tabs,maps:get(id,D)=/=Id]})};
                        false -> {error,<<"Leave this Session before joining another.">>} end end;
            [] when Id=:=<<"default">>;Id=:=Target -> {Id,S};
            [] ->
                true=blank(Id,Tabs),
                Default=default_saved(Target,Tabs),
                Selected=case Default of true -> <<"default">>;false -> Target end,
                case Default of true -> ok;false -> ok=start(Selected) end,
                %% Preserve explicit choices made in the blank tab before Join.
                case in(Id,fun ba_device_config:snapshot/0) of
                    #{revision := Revision,consent := Consent} when Revision>0 ->
                        ok=in(Selected,fun() -> ba_device_config:change(Consent,#{}) end);
                    _ -> ok
                end,
                stop(Id),Next=save(S#{tabs := [case maps:get(id,D)=:=Id of true -> D#{id := Selected};false -> D end || D <- Tabs]}),
                {Selected,Next}
        end
    catch _:_ -> {error,<<"Invalid invitation or Session unavailable.">>} end;
prepare(Id,_,S) -> {Id,S}.
blank(Id,Tabs) -> lists:any(fun(D) -> maps:get(id,D)=:=Id andalso maps:get(buffee,D,null)=:=null end,Tabs).
dispatch(#{<<"method">> := <<"join_buffee">>,<<"invitation">> := Link}=Command) ->
    {_,I}=ba_buffee_passport:parse_invitation(Link),
    case ba_buffee:status() of
        #{buffee := Buffee} when Buffee=:=map_get(<<"buffee">>,I) -> ba_device_api:request(#{<<"method">> => <<"snapshot">>});
        _ -> ba_device_api:request(maps:remove(<<"session">>,Command))
    end;
dispatch(Command) -> ba_device_api:request(maps:remove(<<"session">>,Command)).

default_saved(Target,Tabs) ->
    Saved=ba_device_store:load(buffee_connection,undefined),
    is_map(Saved) andalso maps:get(buffee,Saved,undefined)=:=Target andalso
        not lists:any(fun(D) -> maps:get(id,D)=:=<<"default">> end,Tabs).
