%% Local app boundary. Consent is device-local; no remote caller can enable it.
-module(ba_app_session).
-export([configure/0,configure/1,consent/0,capability/2,snapshot/0,exclude/2,excluded/1,contract/3]).
-ifdef(TEST).
-export([unavailable_capabilities/0]).
-endif.
configure() ->
    case ba_settings:env("BA_PLATFORM") of
        "mac" -> application:set_env(ba_core,restore_session_on_start,true),configure(#{platform => mac});
        "ios" -> application:set_env(ba_core,restore_session_on_start,true),configure(#{platform => ios});
        %% Windows has no audio engine shell yet (plan step 4): no audio.
        "windows" -> configure(#{platform => windows});
        _ -> ok
    end.
configure(#{platform := Platform}) ->
    %% The native audio engine is the only audio path; capture exists on macOS.
    Capture=case Platform of mac -> ba_mac_native_audio;_ -> ba_no_capture end,
    application:set_env(ba_core,audio_automation,true),
    application:set_env(ba_core,audio_capture_adapter,Capture).

consent() ->
    case ba_session_scope:whereis(ba_device_config) of
        undefined -> #{speaker => false,microphone => false,broadcast => false,calibrate_microphone => false,calibrate_speaker => false,dsp => false};
        _ -> C=ba_device_config:consent(),
             B=try ba_session:broadcast() catch exit:_ -> false end,C#{broadcast => B}
    end.
capability(broadcast,B) when is_boolean(B) -> ba_session:broadcast(B);
capability(Key,B) when (Key=:=speaker orelse Key=:=microphone),is_boolean(B) ->
    ba_device_config:change(#{Key => B},#{});
capability(_,_) -> {error,invalid_capability}.
exclusions() -> ba_device_store:load(session_exclusions,[]).
excluded(Peer) -> lists:member(Peer,exclusions()).
exclude(Peer,B) when is_boolean(B) ->
    {Public,_}=ba_device_store:identity(),Self=binary:encode_hex(Public),
    case ba_hex:valid(Peer,64) andalso Peer=/=Self andalso is_pid(ba_session_scope:whereis(ba_session_control)) of
        true ->
            Old=exclusions(),New=case B of true -> lists:usort([Peer|Old]);false -> lists:delete(Peer,Old) end,
            ok=ba_device_store:save(session_exclusions,New),
            ok=ba_session_control:exclude(Peer),ba_device_handler:audio_changed();
        false -> {error,invalid_or_inactive_device}
    end.
contract(Session,Publisher,#{receiver := Receiver,source := Source}) ->
    <<Id:16/binary,_/binary>>=crypto:hash(sha256,term_to_binary({Session,Publisher,Receiver,Source})),binary:encode_hex(Id).
snapshot() ->
    {Public,_}=ba_device_store:identity(),Id=binary:encode_hex(Public),
    Session=ba_session:status(),Config=ba_device_config:snapshot(),
    Base=#{profile => session_control,device => Id,device_name => ba_device_label:local(Id),device_label => ba_device_label:display(unicode:characters_to_binary(ba_settings:env("BA_DEVICE_NAME",ba_device_label:os_name()))),session => Session,connection => ba_session:connection(),contacts => ba_contacts:list(),live => #{microphone => ba_settings:get(mic_live,false)=:=true,muted => ba_settings:get(muted,false)=:=true},
        desks => safe(fun ba_session_desks:status/0,#{}),
        default_desk => ba_session_passport:default_desk(),
        configuration => maps:without([entries],Config),consent => consent(),excluded => exclusions(),messages => [],devices => [],
        audio_diagnostics => ba_audio_diagnostics:options(),audio => #{},clock => #{state => idle},passport => #{},
        unavailable_capabilities => unavailable_capabilities()},
    case maps:get(state,Session) of
        idle -> Base;
        _ ->
            Handler=safe(fun ba_device_handler:status/0,#{}),Control=safe(fun ba_session_control:snapshot/0,#{}),
            Audio=safe(fun() -> case ba_session_scope:whereis(ba_audio_receiver) of undefined -> #{};_ -> ba_audio_receiver:snapshot() end end,#{}),
            Clock=ba_session_clock:status(),
            LocalName=maps:get(<<"device_name">>,maps:get(capabilities,Handler,#{}),ba_device_label:local(Id)),
            Privileges=device_privileges(),
            Devices=[#{id => D,name => case D=:=Id of true -> LocalName;false -> maps:get(D,maps:get(peer_names,Control,#{}),<<>>) end,
                local => D=:=Id,excluded => excluded(D),
                has_error => maps:get(D,maps:get(peer_errors,Control,#{}),false),
                privileges => maps:get(D,Privileges,[]),
                requests => maps:get(D,maps:get(requests,Session,#{}),[]),
                %% Only Devices this one has encountered are listed; connected
                %% while their requests are flowing.
                state => case D=:=Id orelse maps:get(stage,maps:get(D,maps:get(links,Control,#{}),#{}),lapsed)=:=authorized of
                    true -> authorized;false -> disconnected end}
                || D <- maps:get(members,Session,[])],
            Base#{device_name := LocalName,handler => Handler,devices := Devices,audio := Audio,clock := Clock,
                messages := safe(fun ba_session_chat:history/0,[]),
                passport := maps:with([session,owner,grant_holders,membership,privileges,state,epoch,revision],Session)}
    end.
safe(F,Default) -> try F() catch exit:_ -> Default end.
%% Capabilities this platform's capture binding cannot provide, with the reason
%% shown to the user (#{<<"microphone">> | <<"broadcast">> => Text}). Optional
%% adapter callback; native hosts may add their own (iOS sharing picker).
unavailable_capabilities() ->
    Adapter=ba_settings:app(audio_capture_adapter,undefined),
    case is_atom(Adapter) andalso Adapter=/=undefined andalso code:ensure_loaded(Adapter)=:={module,Adapter}
            andalso erlang:function_exported(Adapter,unavailable,0) of
        true -> Adapter:unavailable();
        false -> #{}
    end.
device_privileges() ->
    case ba_session_membership:current() of
        {ok,#{device_privileges := Held}} -> maps:map(fun(_,Wires) -> ba_session_privileges:names(Wires) end,Held);
        _ -> #{}
    end.
