%% Bounded text history for this Session: authenticated chat messages, plus
%% local info entries this Device derives from authenticated links and signed
%% privilege changes. Info entries are never sent; every Device derives its own.
-module(ba_buffee_chat).
-behaviour(gen_server).
-export([start_link/0,send/1,history/0]).
-export([init/1,handle_call/3,handle_cast/2,handle_info/2,terminate/2]).
start_link() -> gen_server:start_link(ba_session_scope:registration(?MODULE),?MODULE,[],[]).
send(Text) -> gen_server:call(ba_session_scope:ref(?MODULE),{send,Text}).
history() -> gen_server:call(ba_session_scope:ref(?MODULE),history).
init([]) ->
    process_flag(trap_exit,true),
    %% One shared handler dispatches notices to the reporting Session.

    logger:add_handler(ba_buffee_chat,ba_buffee_log_h,#{level => error,config => #{recipient => self()}}),
    {ok,#{messages => [],present => [],privileges => undefined}}.
handle_call(history,_,#{messages := M}=S) -> {reply,lists:reverse(M),S};
handle_call({send,Text},_,S) when is_binary(Text),byte_size(Text)>0,byte_size(Text)=<4096 ->
    {Reply,M}=publish(Text,maps:get(messages,S)),{reply,Reply,S#{messages := M}};
handle_call(_,_,S) -> {reply,{error,invalid_text},S}.
handle_cast(_,S) -> {noreply,S}.
handle_info({ba_crash_notice,Text},S) ->
    %% This worker may wait on the ordinary chat API; the failing process never
    %% does. Lost membership/transport simply drops this one attempt.
    M=try publish(Text,maps:get(messages,S)) of {_,Messages} -> Messages catch _:_ -> maps:get(messages,S) end,
    {noreply,S#{messages := M}};
handle_info({buffee_chat,#{peer := Peer,session := Session},Id,Text},S) ->
    case ba_buffee_control:audio_context(Peer) of
        {ok,#{session := Session}} -> {noreply,S#{messages := add(Id,Peer,Text,maps:get(messages,S))}};
        _ -> {noreply,S}
    end;
%% The automatic hello, once per arrival: a Device has proved the Session's link
%% to this one. Control links come and go with policy changes; presence does not.
handle_info({participants,Ids},#{present := Present}=S) ->
    {noreply,lists:foldl(fun(Peer,Acc) -> info(Peer,<<"is here">>,Acc) end,S#{present := Ids},Ids--Present)};
%% Privileges affect everyone, so each signed change is shown to everyone.
%% A request waits for an answer from a Device that can give rights.
handle_info({privilege_requested,Device,Wire},S) ->
    Text=case [T || {Privilege,T} <- [{on_air,<<"asks to go on air">>},{grant,<<"asks for the right to give and take rights">>},
                                      {end_session,<<"asks for the right to end the Session">>}],ba_session_privileges:wire(Privilege)=:=Wire] of
        [T] -> T;[] -> <<"asks for a right">> end,
    {noreply,info(Device,Text,S)};
%% A Device starts or stops sending sound to the Session (seen locally).
handle_info({on_air,Device,true},S) -> {noreply,info(Device,<<"is going on air">>,S)};
handle_info({on_air,Device,false},S) -> {noreply,info(Device,<<"went off air">>,S)};
handle_info({session_privileges,New},#{privileges := undefined}=S) -> {noreply,S#{privileges := New}};
handle_info({session_privileges,New},#{privileges := Old}=S) ->
    Changes=[{Id,Text} || Id <- lists:sort(maps:keys(New)),{Privilege,Gained,Lost} <- named(),
        {Had,Has} <- [{ba_session_privileges:has(Privilege,maps:get(Id,Old,[])),ba_session_privileges:has(Privilege,maps:get(Id,New))}],
        Had=/=Has,Text <- [case Has of true -> Gained;false -> Lost end]]
        ++[{Id,<<"was removed from the Session">>} || Id <- lists:sort(maps:keys(Old)),not maps:is_key(Id,New)],
    {noreply,lists:foldl(fun({Id,Text},Acc) -> info(Id,Text,Acc) end,S#{privileges := New},Changes)};
handle_info(_,S) -> {noreply,S}.
named() ->
    [{on_air,<<"can now go on air">>,<<"can no longer go on air">>},
     {grant,<<"can now give and take privileges">>,<<"can no longer give and take privileges">>},
     {end_session,<<"can now end the Session">>,<<"can no longer end the Session">>}].
%% The text completes a sentence that starts with the subject Device's name.
info(Subject,Text,#{messages := M}=S) ->
    Entry=#{id => binary:encode_hex(crypto:strong_rand_bytes(16)),sender => Subject,text => Text,
            time => erlang:system_time(second),level => info},
    S#{messages := lists:sublist([Entry|M],200)}.
terminate(_,_) ->
    Other=[P || {ba_session,_,ba_buffee_chat}=Name <- global:registered_names(),
        P <- [global:whereis_name(Name)],is_pid(P),P=/=self()],
    Default=erlang:whereis(ba_buffee_chat),
    case Other=:=[] andalso (Default=:=undefined orelse Default=:=self()) of
        true -> logger:remove_handler(ba_buffee_chat);false -> ok end,ok.

publish(Text,S) ->
    Id=binary:encode_hex(crypto:strong_rand_bytes(16)),
    {Pub,_}=ba_device_store:identity(),Self=binary:encode_hex(Pub),
    case ba_buffee_membership:current() of
        {ok,#{policy := #{peers := Peers}}} ->
            Results=[ba_buffee_control:chat_message(P,Id,Text) || P <- maps:keys(Peers),not ba_app_session:excluded(P)],
            Reply=case lists:all(fun(R) -> R=:=ok end,Results) of true -> ok;false -> {error,some_recipients_unavailable} end,
            {Reply,add(Id,Self,Text,S)};
        _ -> {{error,no_authorized_membership},S}
    end.
add(Id,Peer,Text,S) ->
    case lists:any(fun(M) -> maps:get(id,M)=:=Id andalso maps:get(sender,M)=:=Peer end,S) of
        true -> S;
        false -> lists:sublist([#{id => Id,sender => Peer,text => Text,time => erlang:system_time(second)}|S],200)
    end.
