%% A local publication; source identity survives pause, incarnation does not restart.
-module(parvi_audio_source).
-behaviour(gen_server).
-export([start_link/1,init/1,handle_call/3,handle_cast/2,handle_info/2,terminate/2]).
start_link(Args) -> gen_server:start_link(?MODULE,Args,[]).
init({#{source_key := Key} = Offer,Owner}) when is_pid(Owner),node(Owner)=:=node() ->
    ok = parvi_audio:validate_offer(Offer),monitor(process,Owner),
    Inc = binary:encode_hex(crypto:strong_rand_bytes(16)),
    {ok,#{offer => Offer#{paused => false},source_key => Key,incarnation => Inc,owner => Owner,sessions => #{}}}.
handle_call(describe,_,#{offer := Offer,source_key := Key,incarnation := Inc} = S) ->
    {reply,Offer#{source_key => Key,incarnation => Inc},S};
handle_call({attach,Pid},{Receiver,_},#{sessions := Sessions} = S) ->
    case Receiver=:=whereis(parvi_audio_receiver) andalso map_size(Sessions)<16 andalso node(Pid)=:=node() of
        true -> Ref = monitor(process,Pid),{reply,ok,S#{sessions := Sessions#{Ref => Pid}}};
        false -> {reply,{error,unauthorized_or_full},S}
    end;
handle_call({pause,B},{Owner,_},#{owner := Owner,offer := Offer} = S) when is_boolean(B) ->
    parvi_audio_receiver ! {publication_state,self(),B},
    {reply,ok,S#{offer := Offer#{paused := B}}};
handle_call({push,channel,H,PCM},{Owner,_},#{owner := Owner,offer := #{paused := false,profiles := #{channel := D}},sessions := Sessions} = S) ->
    Valid = case is_binary(PCM) andalso byte_size(PCM) div parvi_audio_packet:frame_bytes(D)=<4096 of
        true -> parvi_audio_packet:validate_block(channel,D,H#{sequence => 0},PCM);
        false -> {error,block_too_large}
    end,
    case Valid of
        ok ->
            Replies = [{Pid,try parvi_audio_subscription:push(Pid,H,PCM) catch exit:_ -> {error,closed} end}
                       || Pid <- maps:values(Sessions)],
            {reply,{ok,Replies},S};
        Error -> {reply,Error,S}
    end;
handle_call({push,_,_,_},_,#{offer := #{paused := true}} = S) -> {reply,{error,source_paused},S};
handle_call(_,_,S) -> {reply,{error,invalid_request_or_owner},S}.
handle_cast(_,S) -> {noreply,S}.
handle_info({'DOWN',Ref,process,Pid,_},#{owner := Pid} = S) -> _ = Ref,{stop,normal,S};
handle_info({'DOWN',Ref,process,_,_},#{sessions := Sessions} = S) -> {noreply,S#{sessions := maps:remove(Ref,Sessions)}};
handle_info(_,S) -> {noreply,S}.
terminate(_,_) -> ok.
