%% Bounded text history for this gathering; authenticated session messages only.
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
    {ok,[]}.
handle_call(history,_,S) -> {reply,lists:reverse(S),S};
handle_call({send,Text},_,S) when is_binary(Text),byte_size(Text)>0,byte_size(Text)=<4096 ->
    {Reply,Next}=publish(Text,S),{reply,Reply,Next};
handle_call(_,_,S) -> {reply,{error,invalid_text},S}.
handle_cast(_,S) -> {noreply,S}.
handle_info({ba_crash_notice,Text},S) ->
    %% This worker may wait on the ordinary chat API; the failing process never
    %% does. Lost membership/transport simply drops this one attempt.
    Next=try publish(Text,S) of {_,State} -> State catch _:_ -> S end,
    {noreply,Next};
handle_info({buffee_chat,#{peer := Peer,session := Session},Id,Text},S) ->
    case ba_buffee_control:audio_context(Peer) of
        {ok,#{session := Session}} -> {noreply,add(Id,Peer,Text,S)};
        _ -> {noreply,S}
    end;
handle_info(_,S) -> {noreply,S}.
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
