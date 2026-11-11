%% Read-only Swarm-wide observation using existing signed capability permissions.
%% No audio subscription, hardware access or remote code execution.
-module(ba_swarm_monitor).
-export([snapshot/1]).
snapshot(#{metrics := Metrics,plain := Plain}) when is_boolean(Metrics),is_list(Plain),length(Plain)=<32 ->
    Local=ba_app_session:snapshot(),Swarm=maps:get(swarm,Local),Self=maps:get(device,Local),
    Peers=lists:usort([Self|maps:get(members,Swarm,[])]),Parent=self(),Ref=make_ref(),
    Workers=[{Peer,spawn_monitor(fun() -> Parent ! {Ref,Peer,read(Peer,Self,Metrics andalso not lists:member(Peer,Plain))} end)} || Peer <- Peers],
    Rows=collect(Workers,Ref,erlang:monotonic_time(millisecond)+6500,[]),
    #{swarm => Swarm,device => Self,clock => maps:get(clock,Local),devices => [named(Row,maps:get(contacts,Local)) || Row <- Rows],
      state => maps:get(state,Swarm),observed_at_ms => erlang:system_time(millisecond)}.
named(#{id := Id}=Row,#{contacts := Contacts}) ->
    Caps=maps:get(capabilities,Row,#{}),
    case maps:get(<<"device_name">>,Caps,maps:get(Id,Contacts,<<>>)) of
        <<>> -> Row;Name -> Row#{name => Name}
    end.
read(Self,Self,Metrics) ->
    case whereis(ba_device_handler) of
        undefined ->
            %% An idle Device has no Swarm audio Handler. Report that honestly,
            %% so a local monitor can stay open across Create/Join/Leave.
            #{id => Self,local => true,state => idle,
              name => ba_device_label:local(Self)};
        _ -> #{id => Self,local => true,state => ok,capabilities => ba_device_handler:capabilities(Metrics)}
    end;
read(Peer,_,Metrics) ->
    try
        %% A passive observer still needs an authenticated session to each peer.
        case ba_swarm_control:audio_context(Peer) of
            {ok,_} -> fetch(Peer,Metrics);
            _ -> ba_swarm_control:connect(Peer),#{id => Peer,state => connecting}
        end
    catch exit:_ -> #{id => Peer,state => unavailable} end.
fetch(Peer,Metrics) ->
    Result=ba_swarm_control:read_capabilities(Peer,Metrics),
    case Result of
        {ok,C} -> #{id => Peer,state => ok,capabilities => C};
        {error,R} -> #{id => Peer,state => R}
    end.
collect([],_,_,Rows) -> lists:sort(fun(A,B) -> maps:get(id,A)<maps:get(id,B) end,Rows);
collect(Workers,Ref,Until,Rows) ->
    receive
        {Ref,Peer,Row} ->
            case lists:keytake(Peer,1,Workers) of
                {value,{_,{_,M}},Rest} -> demonitor(M,[flush]),collect(Rest,Ref,Until,[Row|Rows]);
                false -> collect(Workers,Ref,Until,Rows)
            end;
        {'DOWN',M,process,_,_} ->
            case [{P,W} || {P,{_,Mon}=W} <- Workers,Mon=:=M] of
                [{Peer,_}] -> collect(lists:keydelete(Peer,1,Workers),Ref,Until,[#{id => Peer,state => unavailable}|Rows]);
                _ -> collect(Workers,Ref,Until,Rows)
            end
    after max(0,Until-erlang:monotonic_time(millisecond)) ->
        [begin exit(P,kill),demonitor(M,[flush]) end || {_,{P,M}} <- Workers],
        collect([],Ref,Until,[#{id => Peer,state => timeout} || {Peer,_} <- Workers]++Rows)
    end.
