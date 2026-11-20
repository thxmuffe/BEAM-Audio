%% Local app boundary. Consent is device-local; no remote caller can enable it.
-module(ba_app_session).
-export([configure/0,configure/1,consent/0,capability/2,snapshot/0,exclude/2,excluded/1,exclusions/0,contract/3,permissions/0]).
-ifdef(TEST).
-export([unavailable_capabilities/0]).
-endif.
configure() ->
    case ba_settings:env("BA_PLATFORM") of
        "mac" -> application:set_env(ba_core,restore_buffee_on_start,true),configure(#{platform => mac}),forget_snapshots();
        "ios" -> application:set_env(ba_core,restore_buffee_on_start,true),configure(#{platform => ios}),forget_snapshots();
        %% Native AAC through ba_native_stream.exe when the host app ships it.
        "windows" -> configure(#{platform => windows}),ok=ba_windows_native_host:start();
        _ -> ok
    end.
configure(#{platform := Platform}=Options) ->
    %% Native AAC is the only audio path; output is the native stream host.
    Capture=case Platform of mac -> ba_mac_native_audio;windows -> ba_windows_native_audio;_ -> ba_no_capture end,
    application:set_env(ba_core,audio_automation,true),
    application:set_env(ba_core,audio_capture_adapter,Capture),
    application:set_env(ba_core,buffee_default_permissions,permissions()),
    case maps:find(consent,Options) of
        {ok,#{speaker := S,microphone := M,broadcast := B}=C} when is_boolean(S),is_boolean(M),is_boolean(B) ->
            case ba_session_scope:whereis(ba_device_config) of
                undefined -> application:set_env(ba_core,audio_consent,C);
                _ -> ba_device_config:change(C,#{})
            end;
        error -> ok
    end.

permissions() -> [<<"capabilities_read">>,<<"job_offer">>,<<"status_read">>,
    <<"stream_read">>,<<"stream_subscribe">>,<<"time_read">>].
consent() ->
    case ba_session_scope:whereis(ba_device_config) of
        undefined -> case ba_settings:app(runtime_profile,legacy_apps) of
            buffee_control -> #{speaker => false,microphone => false,broadcast => false,calibrate_microphone => false,calibrate_speaker => false,dsp => false};
            _ -> ba_settings:app(audio_consent,#{speaker => true,microphone => false,broadcast => false}) end;
        _ -> C=ba_device_config:consent(),
             case ba_settings:app(runtime_profile,legacy_apps) of
                 buffee_control -> B=try ba_buffee:broadcast() catch exit:_ -> false end,C#{broadcast => B};
                 _ -> C
             end
    end.
capability(broadcast,B) when is_boolean(B) ->
    case ba_settings:app(runtime_profile,legacy_apps) of
        buffee_control -> ba_buffee:broadcast(B);
        _ -> ba_device_config:change(#{broadcast => B},#{})
    end;
capability(Key,B) when (Key=:=speaker orelse Key=:=microphone orelse Key=:=broadcast),is_boolean(B) ->
    ba_device_config:change(#{Key => B},#{});
capability(_,_) -> {error,invalid_capability}.
exclusions() -> ba_device_store:load(buffee_exclusions,[]).
excluded(Peer) -> lists:member(Peer,exclusions()).
exclude(Peer,B) when is_boolean(B) ->
    {Public,_}=ba_device_store:identity(),Self=binary:encode_hex(Public),
    case ba_buffee_job:hex(Peer,64) andalso Peer=/=Self andalso is_pid(ba_session_scope:whereis(ba_buffee_control)) of
        true ->
            Old=exclusions(),New=case B of true -> lists:usort([Peer|Old]);false -> lists:delete(Peer,Old) end,
            ok=ba_device_store:save(buffee_exclusions,New),
            ok=ba_buffee_control:exclude(Peer),ba_device_handler:audio_changed();
        false -> {error,invalid_or_inactive_device}
    end.
contract(Buffee,Publisher,#{receiver := Receiver,source := Source}) ->
    <<Id:16/binary,_/binary>>=crypto:hash(sha256,term_to_binary({Buffee,Publisher,Receiver,Source})),binary:encode_hex(Id).
snapshot() ->
    {Public,_}=ba_device_store:identity(),Id=binary:encode_hex(Public),
    Buffee=ba_buffee:status(),Config=ba_device_config:snapshot(),
    Base=#{profile => buffee_control,device => Id,device_name => ba_device_label:local(Id),device_label => ba_device_label:display(unicode:characters_to_binary(ba_settings:env("BA_DEVICE_NAME",ba_device_label:os_name()))),buffee => Buffee,connection => ba_buffee:connection(),contacts => ba_contacts:list(),live => #{microphone => ba_settings:get(mic_live,false)=:=true,muted => ba_settings:get(muted,false)=:=true},
        desks => safe(fun ba_buffee_desks:status/0,#{}),
        default_desk => ba_settings:app(default_reception_desk_url,<<>>),
        configuration => maps:without([entries],Config),consent => consent(),excluded => exclusions(),messages => [],devices => [],jobs => [],
        audio_diagnostics => ba_audio_diagnostics:options(),audio => #{},clock => #{state => idle},passport => #{},
        unavailable_capabilities => unavailable_capabilities()},
    case maps:get(state,Buffee) of
        idle -> Base;
        _ ->
            Handler=safe(fun ba_device_handler:status/0,#{}),Control=safe(fun ba_buffee_control:snapshot/0,#{}),
            Audio=safe(fun() -> case ba_session_scope:whereis(ba_audio_receiver) of undefined -> #{};_ -> ba_audio_receiver:snapshot() end end,#{}),
            Clock=ba_buffee_clock:status(),
            LocalName=maps:get(<<"device_name">>,maps:get(capabilities,Handler,#{}),ba_device_label:local(Id)),
            Privileges=device_privileges(),
            Devices=[#{id => D,name => case D=:=Id of true -> LocalName;false -> maps:get(D,maps:get(peer_names,Control,#{}),<<>>) end,
                local => D=:=Id,excluded => excluded(D),
                has_error => maps:get(D,maps:get(peer_errors,Control,#{}),false),
                privileges => maps:get(D,Privileges,[]),
                requests => maps:get(D,maps:get(requests,Buffee,#{}),[]),
                %% Only Devices this one has encountered are listed; connected
                %% while their requests are flowing.
                state => case D=:=Id orelse maps:get(stage,maps:get(D,maps:get(sessions,Control,#{}),#{}),lapsed)=:=authorized of
                    true -> authorized;false -> disconnected end}
                || D <- maps:get(members,Buffee,[])],
            LocalJobs=[#{id => atom_to_binary(K),device => Id,capability => K,state => maps:get(state,V,waiting)}
                || {K,V} <- maps:to_list(maps:get(audio,Handler,#{})),maps:get(state,V,disabled)=/=disabled],
            Base#{device_name := LocalName,handler => Handler,devices := Devices,audio := Audio,clock := Clock,
                jobs := LocalJobs++[J#{id => Key} || {Key,J} <- maps:to_list(maps:get(jobs,Control,#{}))],
                messages := safe(fun ba_buffee_chat:history/0,[]),
                passport := maps:with([buffee,owner,grant_holders,membership,privileges,state,epoch,revision],Buffee)}
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
forget_snapshots() ->
    %% Explicit migration: never touch Keychain identity or contacts.term.
    case ba_settings:env("BA_STATE_DIR") of
        false -> ok;
        Dir -> lists:foreach(fun(Name) ->
            case file:delete(filename:join(Dir,Name)) of ok -> ok;{error,enoent} -> ok;{error,R} -> error({snapshot_cleanup_failed,R}) end
        end,["authority.term","policy.term","desk.term","audio_subscription.term","buffee_authority.term","buffee_member.term","buffee_sessions.term","buffee_desks.term","buffee_time_policy.term",
            "buffee_time_cache.term","audio_subscriptions.term","audio_subscription.term","clock_status.json"])
    end.

device_privileges() ->
    case ba_buffee_membership:current() of
        {ok,#{device_privileges := Held}} -> maps:map(fun(_,Wires) -> ba_session_privileges:names(Wires) end,Held);
        _ -> #{}
    end.
