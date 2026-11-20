%% Durable desired Device settings. Runtime observations and Session state are not
%% configuration. One serialized owner records changes from every supported client.
-module(ba_device_config).
-behaviour(gen_server).
-export([start_link/0,consent/0,snapshot/0,change/2,undo/1,redo/1,allowed/1,token/1,policy/1,policy/3,auto_accept/2,auto_grant/2,preset/2,request/2,answer/3]).
%% Device resources the Session may ask to use, and requests from other Devices
%% that this Device answers. Each has a policy: always, ask (default) or no.
%% PROTECTED uses still carry a consent flag; the others are recorded choices only.
-define(PROTECTED,[speaker,microphone,calibrate_microphone,calibrate_speaker,dsp]).
-define(USES,[location]).
%% Requests for rights: on_air, and moderator rights (grant, end_session).
-define(GRANTS,[on_air_requests,moderator_requests]).
-define(ANSWERS,?USES++?GRANTS).
-export([init/1,handle_call/3,handle_cast/2,handle_info/2,format_status/1]).
-define(LIMIT,100).
start_link() -> gen_server:start_link(ba_session_scope:registration(?MODULE),?MODULE,[],[]).
consent() -> gen_server:call(ba_session_scope:ref(?MODULE),consent).
snapshot() -> gen_server:call(ba_session_scope:ref(?MODULE),snapshot).
change(Patch,Options) -> gen_server:call(ba_session_scope:ref(?MODULE),{edit,Patch,Options}).
undo(Options) -> gen_server:call(ba_session_scope:ref(?MODULE),{undo,Options}).
redo(Options) -> gen_server:call(ba_session_scope:ref(?MODULE),{redo,Options}).
policy(Key) -> gen_server:call(ba_session_scope:ref(?MODULE),{policy,Key}).
policy(Key,Value,Options) -> gen_server:call(ba_session_scope:ref(?MODULE),{policy,Key,Value,Options}).
auto_accept(Enabled,Options) -> gen_server:call(ba_session_scope:ref(?MODULE),{auto_accept,Enabled,Options}).
auto_grant(Enabled,Options) -> gen_server:call(ba_session_scope:ref(?MODULE),{auto_grant,Enabled,Options}).
%% Something needs a protected use that is off. Always/allowed: ok. No: refused.
%% Ask: one pending request per requester (a Device ID, or <<"local">>) that this
%% Device's user answers in Requests; a declined requester is not asked again
%% until the policy changes. Never blocks the caller.
request(Key,From) -> gen_server:call(ba_session_scope:ref(?MODULE),{request,Key,From}).
%% The user's answer: Allow turns the use on (a normal, recorded change).
answer(Key,Allow,Options) -> gen_server:call(ba_session_scope:ref(?MODULE),{answer,Key,Allow,Options}).
%% A named bundle of the settings below; only `advanced` leaves them for the person to set.
preset(Name,Options) -> gen_server:call(ba_session_scope:ref(?MODULE),{preset,Name,Options}).
-define(PRESETS,[no_control,friendly,tight,advanced]).
%% What each preset sets: the two top switches and the choices (anything not named asks).
%% `keep` leaves the choices as they are (they are hidden, not changed).
preset_values(no_control) -> #{auto_accept => true,auto_grant => true,choices => keep};
preset_values(friendly) -> #{auto_accept => false,auto_grant => true,
    choices => #{moderator_requests => always,speaker => always,calibrate_microphone => always,calibrate_speaker => always,
                 dsp => always,location => always}};
preset_values(tight) -> #{auto_accept => false,auto_grant => false,
    choices => #{moderator_requests => no,microphone => no,location => no,dsp => no}}.
%% The consent flags a preset's values grant (always, or everything while auto accept is on).
preset_patch(#{auto_accept := Auto,choices := Choices}) ->
    maps:from_list([{K,Auto orelse maps:get(K,Choices,ask)=:=always} || K <- ?PROTECTED]).
%% Read-only, fail-closed view for hot execution paths. Only this owner writes it.
allowed(Key) ->
    try ets:lookup(?MODULE,permissions) of
        [{permissions,C,_,Registry}] -> Registry=/=undefined andalso Registry=:=whereis(ba_permission_pg) andalso maps:get(Key,C,false)=:=true;
        _ -> false
    catch error:badarg -> false end.
init([]) ->
    ets:new(?MODULE,[named_table,protected,set,{read_concurrency,true}]),
    %% The Device starts from its settings: every grant, ON AIR and the standing
    %% choices. Only a first start begins with everything off. Undo history lives
    %% only while the Device runs.
    Gates0=read_gates(ba_settings:get(automation,#{})),
    %% A Device that has no preset yet: one that already has settings keeps them
    %% (advanced); a new one starts in the default preset (tight in the apps).
    Existing=lists:any(fun(K) -> ba_settings:get(K,undefined)=/=undefined end,[automation,consent,contacts]),
    Preset=case maps:get(preset,Gates0,undefined) of
        undefined -> case Existing of
            true -> advanced;
            false -> ba_settings:app(device_default_preset,tight)
        end;
        P -> P
    end,
    {Gates,Fresh}=case {maps:is_key(preset,Gates0),Preset} of
        {false,advanced} -> {Gates0#{preset => advanced},#{}};
        {false,_} -> V=preset_values(Preset),
            {Gates0#{preset => Preset,auto_accept => maps:get(auto_accept,V),auto_grant => maps:get(auto_grant,V),choices => maps:get(choices,V)},preset_patch(V)};
        _ -> {Gates0,#{}}
    end,
    Default=maps:merge(maps:from_keys([broadcast|?PROTECTED],false),Fresh),
    Saved=ba_settings:get(consent,undefined),
    Consent=case valid_config(Saved) of true -> Saved;false -> Default end,
    S=#{format => 1,revision => 0,cursor => 0,seen => [],
        states => [#{label => <<"Initial audio settings">>,config => Consent,time_ms => erlang:system_time(millisecond)}]},
    ok=validate(S),
    Restored=S#{choices => maps:get(choices,Gates,#{}),auto_accept => maps:get(auto_accept,Gates,false),auto_grant => maps:get(auto_grant,Gates,false),preset => maps:get(preset,Gates,advanced)},
    _=save_gates(Restored),
    publish(Restored),changed(),{ok,Restored#{permission_registry => whereis(ba_permission_pg)}}.
%% Only well-formed choices are read back; anything else is dropped.
read_gates(Saved) when is_map(Saved) ->
    Choices=maps:filter(fun(K,V) -> lists:member(K,?PROTECTED++?ANSWERS) andalso lists:member(V,[always,no]) end,
                        case maps:get(choices,Saved,#{}) of C when is_map(C) -> C;_ -> #{} end),
    Base=#{choices => Choices,auto_accept => maps:get(auto_accept,Saved,false)=:=true,auto_grant => maps:get(auto_grant,Saved,false)=:=true},
    case lists:member(maps:get(preset,Saved,undefined),?PRESETS) of true -> Base#{preset => maps:get(preset,Saved)};false -> Base end;
read_gates(_) -> #{}.
%% Written to the settings after every change to a standing choice.
save_gates(S) -> ok=ba_settings:put(automation,maps:with([choices,auto_accept,auto_grant,preset],S)),S.
validate(#{format := 1,revision := R,cursor := C,seen := Seen,states := States}) ->
    true=is_integer(R) andalso R>=0,true=is_list(States) andalso length(States)>0 andalso length(States)=< ?LIMIT+1,
    true=is_integer(C) andalso C>=0 andalso C<length(States),true=is_list(Seen) andalso length(Seen)=< ?LIMIT,
    true=lists:all(fun(Id) -> is_binary(Id) andalso byte_size(Id)>0 andalso byte_size(Id)=<128 end,Seen),
    [begin true=valid_config(Config),true=is_binary(Label),true=is_integer(T) end || #{config := Config,label := Label,time_ms := T} <- States],
    true=lists:all(fun(E) -> is_map(E) andalso maps:is_key(config,E) andalso maps:is_key(label,E) andalso maps:is_key(time_ms,E) end,States),ok.
valid_config(C) when is_map(C) ->
    lists:all(fun(K) -> maps:is_key(K,C) end,[broadcast,microphone,speaker]) andalso
    lists:all(fun(K) -> lists:member(K,[broadcast|?PROTECTED]) end,maps:keys(C)) andalso lists:all(fun is_boolean/1,maps:values(C));
valid_config(_) -> false.
current(#{states := States,cursor := C}) -> maps:get(config,lists:nth(C+1,States)).
public(#{states := States,cursor := C,revision := R}=S) ->
    #{revision => R,consent => current(S),policies => maps:from_list([{K,policy_of(K,S)} || K <- ?PROTECTED++?ANSWERS]),auto_accept => auto(S),auto_grant => maps:get(auto_grant,S,false),preset => maps:get(preset,S,advanced),revocation_pending => maps:get(revocation_pending,S,[]),can_undo => C>0 andalso history_allowed(current(S),maps:get(config,lists:nth(max(1,C),States))),can_redo => C+1<length(States) andalso history_allowed(current(S),maps:get(config,lists:nth(min(length(States),C+2),States))),
      undo_label => case C of 0 -> null;_ -> maps:get(label,lists:nth(C+1,States)) end,
      redo_label => case C+1<length(States) of true -> maps:get(label,lists:nth(C+2,States));false -> null end,
      cursor => C,entries => [E#{selected => I=:=C} || {I,E} <- lists:zip(lists:seq(0,length(States)-1),States)],
      requests => [#{key => K,from => F} || {K,Fs} <- lists:sort(maps:to_list(maps:get(requests,S,#{}))),not maps:get(K,current(S),false),F <- Fs]}.
handle_call(consent,_,S) -> {reply,current(S),S};
handle_call({request,Key,From},_,S) when is_binary(From) ->
    case lists:member(Key,?PROTECTED++?ANSWERS) of
        false -> {reply,{error,invalid_configuration},S};
        true ->
            case request_allowed(Key,S) of
                true -> {reply,ok,S};
                false -> case effective_policy(Key,S) of
                    no -> {reply,{error,refused},S};
                    _ -> pending_request(Key,From,S)
                end
            end
    end;
handle_call({answer,Key,true,Options},From,S) ->
    case lists:member(Key,?PROTECTED) andalso handle_call({edit,#{Key => true},Options},From,S) of
        {reply,ok,Next} -> changed(),{reply,ok,Next#{requests => maps:remove(Key,maps:get(requests,Next,#{}))}};
        false -> {reply,{error,invalid_configuration},S};
        Other -> Other
    end;
handle_call({answer,Key,false,_},_,S) ->
    Declined=maps:get(declined,S,#{}),Asked=maps:get(Key,maps:get(requests,S,#{}),[]),
    changed(),
    {reply,ok,S#{requests => maps:remove(Key,maps:get(requests,S,#{})),
                 declined => Declined#{Key => lists:usort(Asked++maps:get(Key,Declined,[]))}}};
handle_call(snapshot,_,S) -> {reply,public(S),S};
handle_call({policy,Key},_,S) -> {reply,effective_policy(Key,S),S};
%% Trust every Device that asks for a right. Grants nothing on this Device itself.
handle_call({auto_grant,Enabled,_},_,S) when is_boolean(Enabled) -> {reply,ok,save_gates(S#{auto_grant => Enabled,preset => advanced})};
%% Accept every request. The stored choices stay as they are and are ignored
%% while this is on. Turning it off is always recorded, even if a stop is pending.
handle_call({auto_accept,Enabled,Options},From,S) when is_boolean(Enabled) ->
    Patch=maps:from_list([{K,Enabled orelse stored(K,S)=:=always} || K <- ?PROTECTED]),
    case handle_call({edit,Patch,Options},From,S) of
        {reply,ok,Next} -> {reply,ok,save_gates(Next#{auto_accept => Enabled,preset => advanced})};
        {reply,Error,Next} when not Enabled -> {reply,Error,save_gates(Next#{auto_accept => false,preset => advanced})};
        Other -> Other
    end;
%% A preset writes its values as one change (grants first go through the same stop
%% barrier as any other); advanced only marks the choice and changes nothing.
handle_call({preset,advanced,_},_,S) -> {reply,ok,save_gates(S#{preset => advanced})};
handle_call({preset,Name,Options},From,S) ->
    case lists:member(Name,?PRESETS) of
        false -> {reply,{error,invalid_configuration},S};
        true ->
            V=preset_values(Name),Auto=maps:get(auto_accept,V),Choices=case maps:get(choices,V) of keep -> maps:get(choices,S,#{});C -> C end,
            Patch=preset_patch(V#{choices => Choices}),
            %% The barrier takes stops and grants as separate changes: stop first.
            Stops=maps:filter(fun(K,On) -> not On andalso maps:get(K,current(S),false) end,Patch),
            Step=case map_size(Stops) of
                0 -> {reply,ok,S};
                _ -> handle_call({edit,Stops,maps:remove(request_id,Options)},From,S)
            end,
            Again=fun(S1) -> case maps:is_key(expected_revision,Options) of
                true -> Options#{expected_revision => maps:get(revision,S1)};false -> Options end end,
            case Step of
                {reply,ok,S1} ->
                    case handle_call({edit,Patch,Again(S1)},From,S1) of
                        {reply,ok,Next} -> {reply,ok,save_gates(Next#{auto_accept => Auto,auto_grant => maps:get(auto_grant,V),choices => Choices,preset => Name})};
                        Other -> Other
                    end;
                Other -> Other
            end
    end;
%% always is the standing grant; ask and no both keep the grant OFF. Nothing
%% here approves a request: ask only records that the user wants to be asked.
handle_call({policy,Key,Value,Options},From,S) ->
    Keys=case Key of calibration -> [calibrate_microphone,calibrate_speaker];_ -> [Key] end,
    case {lists:member(Value,[always,ask,no]),lists:all(fun(K) -> lists:member(K,?PROTECTED) end,Keys),lists:member(Key,?ANSWERS)} of
        {true,true,_} ->
            Patch=maps:from_keys(Keys,auto(S) orelse Value=:=always),
            case handle_call({edit,Patch,Options},From,S) of
                {reply,ok,Next0} ->
                    Next=Next0#{requests => maps:without(Keys,maps:get(requests,Next0,#{})),declined => maps:without(Keys,maps:get(declined,Next0,#{}))},
                    {reply,ok,lists:foldl(fun(K,Acc) -> choose(K,Value,Acc) end,Next,Keys)};
                Other -> Other
            end;
        {true,_,true} -> {reply,ok,choose(Key,Value,S)};
        _ -> {reply,{error,invalid_configuration},S}
    end;
handle_call(Command,_,S) ->
    try operation(Command,S) of
        unchanged -> case maps:get(revocation_pending,S,[]) of [] -> {reply,ok,S};_ -> commit(S,S) end;
        {error,R} -> {reply,{error,R},S};
        Next -> commit(S,Next)
    catch error:badarg -> {reply,{error,invalid_configuration},S};
          error:{badmatch,false} -> {reply,{error,invalid_configuration},S};
          error:function_clause -> {reply,{error,invalid_configuration},S}
    end.
commit(Old,Next) ->
    case maps:get(permission_registry,Old,whereis(ba_permission_pg))=:=whereis(ba_permission_pg) of
        true -> commit_registered(Old,Next);false -> {reply,{error,permission_registry_lost},Old}
    end.
commit_registered(Old,Next) ->
    Removed=[K || K <- ?PROTECTED,maps:get(K,current(Old),false),not maps:get(K,current(Next),false)],
    Added=[K || K <- ?PROTECTED,not maps:get(K,current(Old),false),maps:get(K,current(Next),false)],
    Pending=maps:get(revocation_pending,Old,[]),
    case {Removed,Added,Pending} of
        {[_|_],[_|_],_} -> {reply,{error,separate_permission_changes_required},Old};
        {_,[_|_],[_|_]} ->
            %% An earlier stop was never confirmed. Retry it now; only if it is
            %% still unconfirmed does the new grant stay blocked.
            case ba_device_permission:revoke(Pending,maps:get(revocation_executors,Old,[])) of
                ok -> Clear=#{revocation_pending => [],revocation_executors => []},
                      commit_registered(maps:merge(Old,Clear),maps:merge(Next,Clear));
                _ -> {reply,{error,revocation_incomplete},Old}
            end;
        {[],_,[]} ->
            case persist(Next) of
                ok -> publish(Next),changed(),{reply,ok,Next};
                {error,R} -> {reply,{error,R},Old}
            end;
        _ ->
            %% Deny BEFORE stopping or disk I/O. A failure never restores a grant.
            publish(Next),Keys=lists:usort(Removed++Pending),
            Stop=ba_device_permission:revoke(Keys,maps:get(revocation_executors,Old,[])),Saved=persist(Next),changed(),
            case {Stop,Saved} of
                {ok,ok} -> {reply,ok,Next#{revocation_pending => [],revocation_executors => []}};
                {ok,{error,R}} -> {reply,{error,R},Next#{revocation_pending => [],revocation_executors => []}};
                {{error,Failed},_} -> {reply,{error,revocation_incomplete},Next#{revocation_pending => Keys,revocation_executors => Failed}}
            end
    end.
operation(Command,S) ->
    Options=element(tuple_size(Command),Command),true=is_map(Options),
    Id=maps:get(request_id,Options,undefined),Expected=maps:get(expected_revision,Options,maps:get(revision,S)),
    case Id=/=undefined andalso lists:member(Id,maps:get(seen,S)) of
        true -> unchanged;
        false ->
            case Expected=:=maps:get(revision,S) of
                false -> {error,configuration_changed};
                true ->
                    true=Id=:=undefined orelse (is_binary(Id) andalso byte_size(Id)>0 andalso byte_size(Id)=<128),
                    case apply_command(Command,S) of
                        unchanged when Id=:=undefined -> unchanged;
                        unchanged -> S#{seen := lists:sublist([Id|maps:get(seen,S)],?LIMIT)};
                        {error,_}=E -> E;
                        Next -> Next#{revision := maps:get(revision,S)+1,
                            seen := case Id of undefined -> maps:get(seen,S);_ -> lists:sublist([Id|maps:get(seen,S)],?LIMIT) end}
                    end
            end
    end.
apply_command({edit,Patch,_},S) when is_map(Patch) ->
    Old=current(S),New=maps:merge(Old,Patch),true=valid_config(New),
    case New=:=Old of
        true -> unchanged;
        false ->
            Changed=[K || K <- [broadcast|?PROTECTED],maps:get(K,Old,false)=/=maps:get(K,New,false)],
            Label=case Changed of
                [K] -> <<(case maps:get(K,New) of true -> <<"Enable ">>;false -> <<"Disable ">> end)/binary,(atom_to_binary(K))/binary>>;
                _ -> <<"Change audio capabilities">>
            end,
            Entry=#{label => Label,config => New,time_ms => erlang:system_time(millisecond)},
            States=lists:sublist(maps:get(states,S),maps:get(cursor,S)+1)++[Entry],
            Kept=lists:nthtail(max(0,length(States)-?LIMIT-1),States),S#{states := Kept,cursor := length(Kept)-1}
    end;
apply_command({undo,_},#{cursor := 0}) -> {error,nothing_to_undo};
apply_command({undo,_},#{cursor := C}=S) -> history_edit(S,S#{cursor := C-1});
apply_command({redo,_},#{cursor := C,states := States}) when C+1>=length(States) -> {error,nothing_to_redo};
apply_command({redo,_},#{cursor := C}=S) -> history_edit(S,S#{cursor := C+1}).
history_edit(Old,New) -> case history_allowed(current(Old),current(New)) of true -> New;false -> {error,local_approval_required} end.
%% The current grants go to the settings; the settings owner writes them to disk.
persist(S) -> try ba_settings:put(consent,current(S)) of ok -> ok;_ -> {error,configuration_save_failed}
              catch _:_ -> {error,configuration_save_failed} end.
token(Key) ->
    try ets:lookup(?MODULE,permissions) of
        [{permissions,C,T,Registry}] -> case Registry=/=undefined andalso Registry=:=whereis(ba_permission_pg) andalso maps:get(Key,C,false) of true -> {ok,maps:get(Key,T)};false -> {error,consent_required} end;
        _ -> {error,consent_required}
    catch error:badarg -> {error,consent_required} end.
publish(S) ->
    C=current(S),{Previous,Tokens}=case ets:lookup(?MODULE,permissions) of
        [{permissions,PC,PT,_}] -> {PC,PT};[] -> {#{},#{}} end,
    T=maps:map(fun(K,V) -> case maps:get(K,Previous,undefined)=:=V of
        true -> maps:get(K,Tokens,make_ref());false -> make_ref() end end,C),
    ets:insert(?MODULE,{permissions,C,T,whereis(ba_permission_pg)}),ok.
changed() ->
    Names=[ba_device_handler|[{global,N} || {ba_session,_,ba_device_handler}=N <- global:registered_names()]],
    [gen_server:cast(Name,audio_changed) || Name <- Names],ok.
history_allowed(Old,New) ->
    not lists:any(fun(K) -> maps:get(K,New,false) andalso not maps:get(K,Old,false) end,?PROTECTED).
%% Protected resources require an installed consent flag; an automation switch
%% must not bypass an unfinished stop or grant operation.
request_allowed(Key,S) ->
    case lists:member(Key,?PROTECTED) of
        true -> maps:get(Key,current(S),false);
        false -> effective_policy(Key,S)=:=always
    end.

%% Approval policy is evaluated here for both rights and resource requests.
effective_policy(Key,S) ->
    Override=case lists:member(Key,?GRANTS) of
        true -> maps:get(auto_grant,S,false);
        false -> auto(S)
    end,
    case Override of true -> always;false -> policy_of(Key,S) end.

%% Rights requests already live on the signed Session board. Resource requests
%% live in Device settings until answered; do not duplicate board entries here.
pending_request(Key,From,S) ->
    case lists:member(Key,?PROTECTED) of
        false -> {reply,{error,waiting_for_approval},S};
        true ->
            Requests=maps:get(requests,S,#{}),Pending=maps:get(Key,Requests,[]),
            case lists:member(From,maps:get(Key,maps:get(declined,S,#{}),[])) of
                true -> {reply,{error,declined},S};
                false ->
                    case length(Pending)>=8 orelse lists:member(From,Pending) of
                        true -> {reply,{error,waiting_for_approval},S};
                        false -> changed(),{reply,{error,waiting_for_approval},S#{requests => Requests#{Key => Pending++[From]}}}
                    end
            end
    end.

auto(S) -> maps:get(auto_accept,S,false).
stored(Key,S) -> maps:get(Key,maps:get(choices,S,#{}),ask).
%% The user's own choice for one item. A grant made or taken another way
%% (the capability command, undo) is reported as what it now is.
policy_of(Key,S) ->
    Stored=stored(Key,S),
    case {lists:member(Key,?ANSWERS),maps:get(Key,current(S),false),Stored,auto(S)} of
        {true,_,_,_} -> Stored;
        {_,true,always,_} -> always;
        {_,true,_,true} -> Stored;
        {_,true,_,false} -> always;
        {_,false,always,_} -> ask;
        {_,false,_,_} -> Stored
    end.
choose(Key,ask,S) -> save_gates(S#{choices => maps:remove(Key,maps:get(choices,S,#{})),preset => advanced});
choose(Key,Value,S) -> save_gates(S#{choices => (maps:get(choices,S,#{}))#{Key => Value},preset => advanced}).
handle_cast(_,S) -> {noreply,S}.
handle_info(_,S) -> {noreply,S}.
format_status(Status) -> maps:map(fun(state,S) -> maps:with([revision,cursor],S);(log,_) -> [];(_,_) -> redacted end,Status).
