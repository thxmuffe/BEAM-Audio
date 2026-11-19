%% A local publication; source identity survives pause, incarnation does not restart.
%% Its audio is captured and sent natively; only control passes through here.
-module(ba_audio_source).
-behaviour(gen_server).
-export([start_link/1,init/1,handle_call/3,handle_cast/2,handle_info/2,terminate/2,format_status/1]).
start_link(Args) -> gen_server:start_link(?MODULE,Args,[]).
init({#{source_key := Key} = Offer,Owner}) when is_pid(Owner),node(Owner)=:=node() ->
    ok = ba_audio:validate_offer(Offer),monitor(process,Owner),
    Inc = binary:encode_hex(crypto:strong_rand_bytes(16)),
    {ok,#{offer => Offer#{paused => false},source_key => Key,incarnation => Inc,owner => Owner,sessions => #{}}}.
handle_call(native_endpoint,_,#{owner := Owner,offer := #{profiles := #{channel := #{stream_handler := native_gst_aac}}}}=S) ->
    {reply,gen_server:call(Owner,native_endpoint,1000),S};
handle_call(describe,_,#{offer := Offer,source_key := Key,incarnation := Inc} = S) ->
    {reply,Offer#{source_key => Key,incarnation => Inc},S};
handle_call({attach,Pid},{Receiver,_},#{sessions := Sessions} = S) ->
    case Receiver=:=ba_session_scope:whereis(ba_audio_receiver) andalso map_size(Sessions)<16 andalso node(Pid)=:=node() of
        true -> Ref = monitor(process,Pid),{reply,ok,S#{sessions := Sessions#{Ref => Pid}}};
        false -> {reply,{error,unauthorized_or_full},S}
    end;
handle_call({rebind,Clock},{Owner,_},#{owner := Owner,offer := #{profiles := #{channel := D}}=Offer,sessions := Sessions}=S)
        when is_binary(Clock),byte_size(Clock)>0,byte_size(Clock)=<128 ->
    %% The receiver owns endpoint shutdown and sends the scoped close first.
    maps:foreach(fun(Ref,_) -> demonitor(Ref,[flush]) end,Sessions),
    Inc = binary:encode_hex(crypto:strong_rand_bytes(16)),
    Next = Offer#{profiles := #{channel => D#{clock := Clock}}},
    ba_session_scope:whereis(ba_audio_receiver) ! {publication_rebound,self(),Next#{source_key => maps:get(source_key,S),incarnation => Inc}},
    {reply,ok,S#{offer := Next,incarnation := Inc,sessions := #{}}};
handle_call({pause,B},{Owner,_},#{owner := Owner,offer := Offer} = S) when is_boolean(B) ->
    ba_session_scope:whereis(ba_audio_receiver) ! {publication_state,self(),B},
    {reply,ok,S#{offer := Offer#{paused := B}}};
handle_call(_,_,S) -> {reply,{error,invalid_request_or_owner},S}.
handle_cast(_,S) -> {noreply,S}.
handle_info({'DOWN',Ref,process,Pid,_},#{owner := Pid} = S) -> _ = Ref,{stop,normal,S};
handle_info({'DOWN',Ref,process,_,_},#{sessions := Sessions} = S) -> {noreply,S#{sessions := maps:remove(Ref,Sessions)}};
handle_info(_,S) -> {noreply,S}.
terminate(_,_) -> ok.
format_status(Status) ->
    maps:map(fun(state,S) -> maps:with([source_key,incarnation],S);(log,_) -> [];(_,_) -> redacted end,Status).
