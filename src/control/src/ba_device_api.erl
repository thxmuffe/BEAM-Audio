%% Device-local commands shared by app bridges and CLI. Never network RPC.
-module(ba_device_api).
-export([request/1,readiness/1,readiness/2]).
request(Request) when is_map(Request) ->
    Reply=try command(Request) of
        {ok,Data} -> (ba_app_session:snapshot())#{<<"error">> => null,<<"result">> => Data};
        ok -> (ba_app_session:snapshot())#{<<"error">> => null};
        null -> (ba_app_session:snapshot())#{<<"error">> => null};
        {error,R} -> (ba_app_session:snapshot())#{<<"error">> => printable(R)}
    catch _:_ -> (ba_app_session:snapshot())#{<<"error">> => <<"Invalid request or unavailable worker.">>} end,
    maps:merge(Reply,maps:with([<<"request_id">>],Request));
request(_) -> request(#{}).
printable(owner_or_valid_invitation_required) -> <<"Rejoin using an invitation to recover the shareable link.">>;
printable(configuration_changed) -> <<"Settings changed in another client. Review the latest state and retry.">>;
printable(invalid_buffee_config) -> <<"Invalid Session name, Reception address or invitation link.">>;
printable(R) when is_binary(R) -> R;
printable(R) when is_atom(R) -> atom_to_binary(R);
printable(R) -> iolist_to_binary(io_lib:format("~p",[R])).

command(#{<<"method">> := <<"monitor">>}=R) -> {ok,ba_buffee_monitor:snapshot(#{metrics => maps:get(<<"metrics">>,R,false),plain => maps:get(<<"plain">>,R,[])})};
command(#{<<"method">> := <<"readiness">>}=R) ->
    {ok,readiness(ba_app_session:snapshot(),maps:get(<<"previous">>,R,#{}))};
command(#{<<"method">> := <<"audio_lifecycle">>,<<"active">> := Active}) when is_boolean(Active) ->
    application:set_env(ba_core,audio_suspended,not Active),
    case ba_session_scope:whereis(ba_audio_receiver) of
        undefined -> ok;
        _ when Active -> ba_audio_receiver:resume();
        _ -> ba_audio_receiver:suspend()
    end,
    case ba_session_scope:whereis(ba_device_handler) of undefined -> ok;_ -> ba_device_handler:audio_changed() end;
command(#{<<"method">> := <<"network_changed">>}) ->
    case ba_session_scope:whereis(ba_audio_receiver) of undefined -> ok;_ -> ba_audio_receiver:network_changed(),ok end;
command(#{<<"method">> := <<"undo">>}=R) -> ba_device_config:undo(config_options(R));
command(#{<<"method">> := <<"redo">>}=R) -> ba_device_config:redo(config_options(R));
command(#{<<"method">> := <<"configuration">>}) -> {ok,ba_device_config:snapshot()};
command(#{<<"method">> := <<"capabilities">>,<<"consent">> := Values}=R) ->
    Patch=maps:from_list([{capability_key(K),B} || {K,B} <- maps:to_list(Values)]),
    ba_device_config:change(Patch,config_options(R));
command(#{<<"method">> := <<"capability">>,<<"capability">> := K,<<"enabled">> := B}=R) ->
    ba_device_config:change(#{capability_key(K) => B},config_options(R));
command(#{<<"method">> := <<"exclude">>,<<"device">> := Id,<<"excluded">> := B}) -> ba_app_session:exclude(Id,B);
command(#{<<"method">> := <<"request_chef">>}) -> ba_buffee_membership:request_chef();
command(#{<<"method">> := <<"send">>,<<"text">> := Text}) -> ba_buffee_chat:send(Text);
command(#{<<"method">> := <<"offset">>,<<"offset_ms">> := Offset}) -> ba_buffee_clock:set_offset(Offset);
command(#{<<"method">> := <<"inspect">>,<<"device">> := Device}) ->
    {Pub,_}=ba_device_store:identity(),
    case Device=:=binary:encode_hex(Pub) of true -> {ok,ba_device_handler:capabilities()};false -> ba_buffee_control:read_capabilities(Device) end;
command(#{<<"method">> := <<"invitation">>}) -> ba_buffee_membership:invite(null);
command(#{<<"method">> := <<"snapshot">>}) -> null;
command(#{<<"method">> := <<"list_contacts">>}) ->
    {ok, ba_contacts:list()};
command(#{<<"method">> := <<"save_contact">>,<<"value">> := Value,<<"name">> := Name}) ->
    case ba_buffee_job:hex(Value,64) of
        true -> ba_contacts:put(Value,Name);
        false -> {_,I}=ba_buffee_passport:parse_invitation(Value),ba_contacts:put(maps:get(<<"authority">>,I),Name)
    end;
command(#{<<"method">> := <<"contact_from_invitation">>,<<"invitation">> := Link,<<"name">> := Name}) ->
    {_,I}=ba_buffee_passport:parse_invitation(Link),ba_contacts:put(maps:get(<<"authority">>,I),Name);
command(#{<<"method">> := <<"put_contact">>, <<"id">> := Id, <<"name">> := Name}) ->
    ba_contacts:put(Id, Name);
command(#{<<"method">> := <<"delete_contact">>, <<"id">> := Id}) ->
    ba_contacts:delete(Id);
command(#{<<"method">> := <<"put_group">>, <<"name">> := Name, <<"ids">> := Ids}) ->
    ba_contacts:group(Name, Ids);
command(#{<<"method">> := <<"delete_group">>, <<"name">> := Name}) ->
    ba_contacts:delete_group(Name);
command(#{<<"method">> := <<"create_buffee">>, <<"name">> := Name, <<"desks">> := Desks}) ->
    ba_buffee:create(Name, Desks);
command(#{<<"method">> := <<"join_buffee">>, <<"invitation">> := Link}) ->
    ba_buffee:join(Link);
command(#{<<"method">> := <<"invite">>, <<"selection">> := Sel} = Req) ->
    TTL = maps:get(<<"ttl">>, Req, null),
    Selection = case Sel of
        #{<<"group">> := G} -> {group, G};
        Ids when is_list(Ids) -> Ids
    end,
    ba_buffee:invite(Selection, TTL);
command(#{<<"method">> := <<"set_role">>,<<"device">> := Device,<<"role">> := Role}) ->
    ba_buffee_membership:set_role(Device,role(Role));
command(#{<<"method">> := <<"remove_device">>,<<"device">> := Device}) ->
    ba_buffee_membership:revoke(Device);
command(#{<<"method">> := <<"leave_buffee">>}) ->
    ba_buffee:leave();
command(#{<<"method">> := <<"end_buffee">>}) ->
    ba_buffee:end_buffee();
command(_) ->
    {error, <<"Unsupported request.">>}.

capability_key(<<"speaker">>) -> speaker;
capability_key(<<"microphone">>) -> microphone;
capability_key(<<"broadcast">>) -> broadcast.
config_options(R) -> maps:from_list([{K,V} || {Wire,K} <- [{<<"request_id">>,request_id},{<<"expected_revision">>,expected_revision}],
    {ok,V} <- [maps:find(Wire,R)]]).


%% Predicates are shared policy, not delays chosen by individual UIs/scripts.
readiness(S) ->
    Buffee=maps:get(buffee,S),Consent=maps:get(consent,S),
    Rows=maps:get(audio,maps:get(handler,S,#{}),#{}),
    Failures=[#{capability => K,error => maps:get(error,R,<<"Audio failed.">>)} || {K,R} <- maps:to_list(Rows),maps:get(state,R,waiting)=:=error],
    Captures=lists:all(fun(K) -> not maps:get(K,Consent) orelse maps:get(state,maps:get(K,Rows,#{}),waiting)=:=running end,[microphone,broadcast]),
    Authorized=maps:get(state,Buffee,idle)=:=authorized,
    Clock=maps:get(state,maps:get(clock,S,#{}),idle),
    ClockReady=Clock=:=synchronized andalso maps:get(ready,maps:get(offset_policy,maps:get(clock,S,#{}),#{}),false),
    Subs=maps:get(subscriptions,maps:get(audio,S,#{}),#{}),
    Receiving=lists:any(fun(I) -> maps:get(state,I,waiting)=:=active andalso maps:get(playing,I,false) andalso maps:get(mix_ready,I,false) end,maps:values(Subs)),
    Progress=#{microphone => maps:get(blocks,maps:get(microphone,Rows,#{}),0),
        broadcast => maps:get(blocks,maps:get(broadcast,Rows,#{}),0),
        speaker => maps:get(rendered,maps:get(mixer,maps:get(audio,S,#{}),#{}),0)},
    #{endpoint => true,admitted => Authorized,clock => ClockReady,consent => Consent,
      membership_state => maps:get(state,Buffee,idle),
      clock_status => maps:with([state,last_error,filter_sample_count,filter_required_samples,offset_policy,uncertainty_ns],maps:get(clock,S,#{})),
      capabilities => Rows,desks => maps:get(desks,S,#{}),
      receiving => Receiving,progress => Progress,
      ready => Authorized andalso ClockReady andalso Captures andalso Failures=:=[],
      failures => Failures}.

flowing(#{ready := true,consent := Consent,progress := Progress,receiving := Receiving},Previous) ->
    Enabled=[K || {K,true} <- maps:to_list(Consent)],
    Enabled=/=[] andalso lists:all(fun(K) ->
        (K=/=speaker orelse Receiving) andalso
        maps:get(K,Progress,0)>maps:get(atom_to_binary(K),Previous,maps:get(K,Previous,0))
    end,Enabled);
flowing(_,_) -> false.

readiness(S,Previous) ->
    View=readiness(S),View#{'audio-flowing' => flowing(View,Previous)}.

role(<<"chef">>) -> chef;
role(<<"guest">>) -> guest;
role(<<"owner">>) -> owner;
role(<<"remove_owner">>) -> remove_owner.
