%% Bounded text history for this gathering; authenticated session messages only.
-module(ba_swarm_chat).
-behaviour(gen_server).
-export([start_link/0,send/1,history/0]).
-export([init/1,handle_call/3,handle_cast/2,handle_info/2]).
start_link() -> gen_server:start_link({local,?MODULE},?MODULE,[],[]).
send(Text) -> gen_server:call(?MODULE,{send,Text}).
history() -> gen_server:call(?MODULE,history).
init([]) -> {ok,[]}.
handle_call(history,_,S) -> {reply,lists:reverse(S),S};
handle_call({send,Text},_,S) when is_binary(Text),byte_size(Text)>0,byte_size(Text)=<4096 ->
    Id=binary:encode_hex(crypto:strong_rand_bytes(16)),
    {Pub,_}=ba_device_store:identity(),Self=binary:encode_hex(Pub),
    case ba_swarm_membership:current() of
        {ok,#{policy := #{peers := Peers}}} ->
            Results=[ba_swarm_control:chat_message(P,Id,Text) || P <- maps:keys(Peers),not ba_app_session:excluded(P)],
            Reply=case lists:all(fun(R) -> R=:=ok end,Results) of true -> ok;false -> {error,some_recipients_unavailable} end,
            {reply,Reply,add(Id,Self,Text,S)};
        _ -> {reply,{error,no_authorized_membership},S}
    end;
handle_call(_,_,S) -> {reply,{error,invalid_text},S}.
handle_cast(_,S) -> {noreply,S}.
handle_info({swarm_chat,#{peer := Peer,session := Session},Id,Text},S) ->
    case ba_swarm_control:audio_context(Peer) of
        {ok,#{session := Session}} -> {noreply,add(Id,Peer,Text,S)};
        _ -> {noreply,S}
    end;
handle_info(_,S) -> {noreply,S}.
add(Id,Peer,Text,S) ->
    case lists:any(fun(M) -> maps:get(id,M)=:=Id andalso maps:get(sender,M)=:=Peer end,S) of
        true -> S;
        false -> lists:sublist([#{id => Id,sender => Peer,text => Text,time => erlang:system_time(second)}|S],200)
    end.
