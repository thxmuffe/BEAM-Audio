%% Local app boundary. Consent is device-local; no remote caller can enable it.
-module(ba_app_session).
-export([configure/0,configure/1,consent/0,capability/2,snapshot/0,exclude/2,excluded/1,exclusions/0,contract/3,permissions/0]).
configure() ->
    case os:getenv("BA_PLATFORM") of
        "mac" -> application:set_env(ba_core,restore_swarm_on_start,true),configure(#{platform => mac}),forget_snapshots();
        "ios" -> application:set_env(ba_core,restore_swarm_on_start,true),configure(#{platform => ios}),forget_snapshots();
        _ -> ok
    end.
configure(#{platform := Platform}=Options) ->
    {Capture,Output}=case Platform of mac -> {ba_mac_audio,ba_mac_output};ios -> {ba_ios_input,ba_ios_audio} end,
    application:set_env(ba_core,audio_automation,true),
    application:set_env(ba_core,audio_capture_adapter,Capture),
    application:set_env(ba_core,audio_output_adapter,Output),
    application:set_env(ba_core,swarm_default_permissions,permissions()),
    case maps:find(consent,Options) of
        {ok,#{speaker := S,microphone := M,broadcast := B}=C} when is_boolean(S),is_boolean(M),is_boolean(B) ->
            case whereis(ba_device_config) of
                undefined -> application:set_env(ba_core,audio_consent,C);
                _ -> ba_device_config:change(C,#{})
            end;
        error -> ok
    end.

permissions() -> [<<"capabilities_read">>,<<"job_offer">>,<<"offset_write">>,<<"status_read">>,
    <<"stream_read">>,<<"stream_subscribe">>,<<"time_read">>].
consent() ->
    case whereis(ba_device_config) of
        undefined -> application:get_env(ba_core,audio_consent,#{speaker => true,microphone => false,broadcast => false});
        _ -> ba_device_config:consent()
    end.
capability(Key,B) when (Key=:=speaker orelse Key=:=microphone orelse Key=:=broadcast),is_boolean(B) ->
    ba_device_config:change(#{Key => B},#{});
capability(_,_) -> {error,invalid_capability}.
exclusions() -> ba_device_store:load(swarm_exclusions,[]).
excluded(Peer) -> lists:member(Peer,exclusions()).
exclude(Peer,B) when is_boolean(B) ->
    {Public,_}=ba_device_store:identity(),Self=binary:encode_hex(Public),
    case ba_swarm_job:hex(Peer,64) andalso Peer=/=Self andalso is_pid(whereis(ba_swarm_control)) of
        true ->
            Old=exclusions(),New=case B of true -> lists:usort([Peer|Old]);false -> lists:delete(Peer,Old) end,
            ok=ba_device_store:save(swarm_exclusions,New),
            ok=ba_swarm_control:exclude(Peer),ba_device_handler:audio_changed();
        false -> {error,invalid_or_inactive_device}
    end.
contract(Swarm,Publisher,#{receiver := Receiver,source := Source}) ->
    <<Id:16/binary,_/binary>>=crypto:hash(sha256,term_to_binary({Swarm,Publisher,Receiver,Source})),binary:encode_hex(Id).
snapshot() ->
    {Public,_}=ba_device_store:identity(),Id=binary:encode_hex(Public),
    Swarm=ba_swarm:status(),Config=ba_device_config:snapshot(),
    Base=#{profile => swarm_control,device => Id,device_name => ba_device_label:local(Id),swarm => Swarm,connection => ba_swarm:connection(),contacts => ba_contacts:list(),
        desks => safe(fun ba_swarm_desks:status/0,#{}),
        default_desk => application:get_env(ba_core,default_reception_desk_url,<<>>),
        configuration => maps:without([entries],Config),consent => maps:get(consent,Config),excluded => exclusions(),messages => [],devices => [],jobs => [],
        audio => #{},clock => #{state => idle},passport => #{}},
    case maps:get(state,Swarm) of
        idle -> Base;
        _ ->
            Handler=safe(fun ba_device_handler:status/0,#{}),Control=safe(fun ba_swarm_control:snapshot/0,#{}),
            Audio=safe(fun() -> case whereis(ba_audio_receiver) of undefined -> #{};_ -> ba_audio_receiver:snapshot() end end,#{}),
            Clock=ba_swarm_clock:status(),
            LocalName=maps:get(<<"device_name">>,maps:get(capabilities,Handler,#{}),ba_device_label:local(Id)),
            Devices=[#{id => D,name => case D=:=Id of true -> LocalName;false -> maps:get(D,maps:get(peer_names,Control,#{}),<<>>) end,
                local => D=:=Id,excluded => excluded(D),
                captain => D=:=maps:get(captain,Swarm),
                state => case D=:=Id of true -> authorized;false -> maps:get(stage,maps:get(D,maps:get(sessions,Control,#{}),#{}),disconnected) end}
                || D <- maps:get(members,Swarm,[])],
            LocalJobs=[#{id => atom_to_binary(K),device => Id,capability => K,state => maps:get(state,V,waiting)}
                || {K,V} <- maps:to_list(maps:get(audio,Handler,#{})),maps:get(state,V,disabled)=/=disabled],
            Base#{device_name := LocalName,handler => Handler,devices := Devices,audio := Audio,clock := Clock,
                jobs := LocalJobs++[J#{id => Key} || {Key,J} <- maps:to_list(maps:get(jobs,Control,#{}))],
                messages := safe(fun ba_swarm_chat:history/0,[]),
                passport := maps:with([swarm,captain,membership,role,state,epoch,revision],Swarm)}
    end.
safe(F,Default) -> try F() catch exit:_ -> Default end.
forget_snapshots() ->
    %% Explicit migration: never touch Keychain identity or contacts.term.
    case os:getenv("BA_STATE_DIR") of
        false -> ok;
        Dir -> lists:foreach(fun(Name) ->
            case file:delete(filename:join(Dir,Name)) of ok -> ok;{error,enoent} -> ok;{error,R} -> error({snapshot_cleanup_failed,R}) end
        end,["authority.term","policy.term","desk.term","audio_subscription.term","swarm_authority.term","swarm_member.term","swarm_desks.term","swarm_time_policy.term",
            "swarm_time_cache.term","audio_subscriptions.term","audio_subscription.term","clock_status.json"])
    end.
