%% Device-local commands shared by app bridges and CLI. Never network RPC.
-module(ba_device_api).
-export([request/1,readiness/1,readiness/2,client_methods/0,methods/0]).
%% Public owner-local commands. The generic CLI uses this list directly;
%% command arguments and their validation belong to the Device API below.
methods() -> lists:usort(client_methods()++[
    <<"monitor">>,<<"readiness">>,<<"configuration">>,<<"capabilities">>,
    <<"list_contacts">>,<<"contact_from_invitation">>,<<"put_contact">>,
    <<"network_changed">>,<<"audio_lifecycle">>]).
%% The one list of commands an app window may send (web, Mac, iOS, Windows).
client_methods() ->
    [<<"audio_diagnostics">>,<<"answer_consent">>,<<"rename_session">>,<<"list_sessions">>,<<"new_session">>,<<"close_session">>,<<"snapshot">>,<<"create_buffee">>,<<"join_buffee">>,<<"leave_buffee">>,
     <<"end_buffee">>,<<"capability">>,<<"policy">>,<<"auto_accept">>,<<"auto_grant">>,<<"preset">>,<<"decline_privilege">>,<<"rename_saved_session">>,<<"forget_saved_session">>,
     <<"ui_get">>,<<"ui_set">>,<<"microphone_live">>,<<"speaker_mute">>,<<"undo">>,<<"redo">>,<<"send">>,<<"offset">>,<<"inspect">>,<<"invitation">>,<<"invite">>,
     <<"request_privilege">>,<<"grant_privilege">>,<<"take_privilege">>,<<"remove_device">>,<<"exclude">>,
     <<"save_contact">>,<<"delete_contact">>,<<"put_group">>,<<"delete_group">>].
request(Request) when is_map(Request) ->
    %% The owner's local commands are this Device's user deciding; remote
    %% requests are decided by ba_device_request instead.
    Reply=try command(Request) of
        {ok,Data} -> (ba_app_session:snapshot())#{<<"error">> => null,<<"result">> => Data};
        ok -> (ba_app_session:snapshot())#{<<"error">> => null};
        null -> (ba_app_session:snapshot())#{<<"error">> => null};
        {error,R} -> (ba_app_session:snapshot())#{<<"error">> => printable(R)}
    catch _:_ -> (ba_app_session:snapshot())#{<<"error">> => <<"Invalid request or unavailable worker.">>} end,
    maps:merge(Reply,maps:with([<<"request_id">>],Request));
request(_) -> request(#{}).
printable(owner_or_valid_invitation_required) -> <<"Rejoin using an invitation to recover the shareable link.">>;
printable(revocation_incomplete) -> <<"Permission is OFF, but stopping has not been confirmed. New grants are blocked; retry OFF or restart the app.">>;
printable(grant_required) -> <<"Only a Device with the grant privilege can change privileges.">>;
printable(kick_privilege_required) -> <<"This Device needs moderator rights to remove a Device.">>;
printable(end_privilege_required) -> <<"This Device needs moderator rights to end the Session.">>;
printable(waiting_for_approval) -> <<"Waiting for this Device's approval in Requests.">>;
printable(declined) -> <<"Declined on this Device. Change the choice in Settings to ask again.">>;
printable(refused) -> <<"Not allowed in this Device's Settings.">>;
printable(grant_holder_unavailable) -> <<"No Device that can grant privileges is reachable right now.">>;
printable(local_approval_required) -> <<"Enable this permission explicitly in My Device; history cannot grant access.">>;
printable(configuration_changed) -> <<"Settings changed in another client. Review the latest state and retry.">>;
printable(invalid_buffee_config) -> <<"Invalid Session name, Reception address or invitation link.">>;
printable(R) when is_binary(R) -> R;
printable(R) when is_atom(R) -> atom_to_binary(R);
printable(R) -> iolist_to_binary(io_lib:format("~p",[R])).

command(#{<<"method">> := <<"audio_diagnostics">>,<<"options">> := Options}=R) ->
    case maps:find(<<"device">>,R) of
        {ok,Device} -> ba_buffee_monitor:configure(Device,Options);
        error -> ba_audio_diagnostics:configure(Options)
    end;
command(#{<<"method">> := <<"audio_diagnostics">>}) -> {ok,ba_audio_diagnostics:options()};
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
command(#{<<"method">> := <<"capability">>,<<"capability">> := <<"broadcast">>,<<"enabled">> := B}) -> ba_app_session:capability(broadcast,B);
command(#{<<"method">> := <<"capability">>,<<"capability">> := K,<<"enabled">> := B}=R) ->
    ba_device_config:change(#{capability_key(K) => B},config_options(R));
%% This Device's user answers a pending Ask request for one of its own uses.
command(#{<<"method">> := <<"answer_consent">>,<<"key">> := K,<<"allow">> := Allow}=R) when is_boolean(Allow) ->
    ba_device_config:answer(capability_key(K),Allow,config_options(R));
command(#{<<"method">> := <<"auto_accept">>,<<"enabled">> := Enabled}=R) when is_boolean(Enabled) ->
    ba_device_config:auto_accept(Enabled,config_options(R));
command(#{<<"method">> := <<"preset">>,<<"name">> := Name}=R) ->
    case Name of
        <<"no_control">> -> ba_device_config:preset(no_control,config_options(R));
        <<"friendly">> -> ba_device_config:preset(friendly,config_options(R));
        <<"tight">> -> ba_device_config:preset(tight,config_options(R));
        <<"advanced">> -> ba_device_config:preset(advanced,config_options(R));
        _ -> {error,<<"Unknown preset.">>}
    end;
command(#{<<"method">> := <<"auto_grant">>,<<"enabled">> := Enabled}=R) when is_boolean(Enabled) ->
    ba_device_config:auto_grant(Enabled,config_options(R));
command(#{<<"method">> := <<"decline_privilege">>,<<"device">> := Device,<<"privilege">> := Name}) ->
    ba_buffee_membership:decline_privilege(Device,ba_session_privileges:parse(Name));
command(#{<<"method">> := <<"policy">>,<<"key">> := K,<<"value">> := V}=R) ->
    Key=case K of
        <<"on_air_requests">> -> on_air_requests;
        <<"moderator_requests">> -> moderator_requests;
        <<"location">> -> location;
        _ -> capability_key(K)
    end,
    Value=case V of <<"always">> -> always;<<"ask">> -> ask;<<"no">> -> no end,
    ba_device_config:policy(Key,Value,config_options(R));
command(#{<<"method">> := <<"exclude">>,<<"device">> := Id,<<"excluded">> := B}) -> ba_app_session:exclude(Id,B);
command(#{<<"method">> := <<"rename_session">>,<<"name">> := Name}) -> ba_buffee_membership:rename(Name);
command(#{<<"method">> := <<"request_privilege">>,<<"privilege">> := Name}) ->
    ba_buffee_membership:request_privilege(ba_session_privileges:parse(Name));
command(#{<<"method">> := <<"grant_privilege">>,<<"device">> := Device,<<"privilege">> := Name}) ->
    ba_buffee_membership:grant_privilege(Device,ba_session_privileges:parse(Name));
command(#{<<"method">> := <<"take_privilege">>,<<"device">> := Device,<<"privilege">> := Name}) ->
    ba_buffee_membership:take_privilege(Device,ba_session_privileges:parse(Name));
command(#{<<"method">> := <<"send">>,<<"text">> := Text}) -> ba_buffee_chat:send(Text);
command(#{<<"method">> := <<"offset">>,<<"automatic">> := Automatic}) when is_boolean(Automatic) -> ba_buffee_clock:set_automatic(Automatic);
command(#{<<"method">> := <<"offset">>,<<"offset_ms">> := Offset}) -> ba_buffee_clock:set_offset(Offset);
command(#{<<"method">> := <<"inspect">>,<<"device">> := Device}) ->
    {Pub,_}=ba_device_store:identity(),
    case Device=:=binary:encode_hex(Pub) of true -> {ok,ba_device_handler:capabilities()};false -> ba_buffee_control:read_capabilities(Device) end;
command(#{<<"method">> := <<"invitation">>}) -> remember_link(ba_buffee_membership:invite(null));
command(#{<<"method">> := <<"snapshot">>}) -> null;
command(#{<<"method">> := <<"list_contacts">>}) ->
    {ok, ba_contacts:list()};
command(#{<<"method">> := <<"save_contact">>,<<"value">> := Value,<<"name">> := Name}) ->
    case ba_hex:valid(Value,64) of
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
%% A Session exists once its invitation link exists: creating one makes its link.
command(#{<<"method">> := <<"create_buffee">>, <<"name">> := Name, <<"desks">> := Desks}=C) ->
    case ba_buffee:create(Name, Desks, maps:get(<<"nonce">>, C, undefined)) of
        ok -> _=try remember_link(ba_buffee_membership:invite(null)) catch _:_ -> ok end,ok;
        Other -> Other
    end;
command(#{<<"method">> := <<"join_buffee">>, <<"invitation">> := Link}) ->
    case ba_buffee:join(Link) of ok -> ba_contacts:link(Link),ok;Other -> Other end;
%% Live audio actions next to ON AIR; saved like every Device setting.
command(#{<<"method">> := <<"microphone_live">>,<<"enabled">> := B}) when is_boolean(B) -> ba_settings:put(mic_live,B);
command(#{<<"method">> := <<"speaker_mute">>,<<"muted">> := B}) when is_boolean(B) -> ba_settings:put(muted,B);
%% The window's own state (which page is open) is a Device setting like the rest.
command(#{<<"method">> := <<"ui_get">>}) -> {ok,ba_settings:get(ui,#{})};
command(#{<<"method">> := <<"ui_set">>,<<"key">> := <<"view">>,<<"value">> := View}) ->
    case lists:member(View,[<<"home">>,<<"chat">>,<<"contacts">>,<<"share">>,<<"settings">>]) of
        true -> _=ba_settings:update(ui,fun(UI) -> UI#{view => View} end,#{}),ok;
        false -> {error,<<"Unknown page.">>}
    end;
command(#{<<"method">> := <<"forget_saved_session">>,<<"entry">> := Session}) ->
    case ba_contacts:forget_session(Session) of
        ok -> ba_sessions:forget(Session);
        Error -> Error
    end;
command(#{<<"method">> := <<"rename_saved_session">>,<<"entry">> := Session,<<"name">> := Name}) ->
    ba_contacts:rename_session(Session,Name);
command(#{<<"method">> := <<"invite">>, <<"selection">> := Sel} = Req) ->
    TTL = maps:get(<<"ttl">>, Req, null),
    Selection = case Sel of
        #{<<"group">> := G} -> {group, G};
        Ids when is_list(Ids) -> Ids
    end,
    ba_buffee:invite(Selection, TTL);
%% A kicked Device stays in this Device's memory of the Session, marked kicked.
command(#{<<"method">> := <<"remove_device">>,<<"device">> := Device}) ->
    case ba_buffee_membership:revoke(Device) of
        ok -> case ba_buffee:status() of #{buffee := Session} -> ba_contacts:kicked(Session,Device);_ -> ok end,ok;
        Other -> Other
    end;
command(#{<<"method">> := <<"leave_buffee">>}) ->
    ba_buffee:leave();
command(#{<<"method">> := <<"end_buffee">>}) ->
    ba_buffee:end_buffee();
command(_) ->
    {error, <<"Unsupported request.">>}.

remember_link({ok,Link}=Result) when is_binary(Link) -> ba_contacts:link(Link),Result;
remember_link(Result) -> Result.

capability_key(<<"calibrate_microphone">>) -> calibrate_microphone;
capability_key(<<"calibrate_speaker">>) -> calibrate_speaker;
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

