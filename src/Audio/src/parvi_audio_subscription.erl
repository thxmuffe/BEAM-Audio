%% A local, temporary WebRTC PCM endpoint. No remote PIDs or OTP carrier.
-module(parvi_audio_subscription).
-behaviour(gen_server).
-export([start_link/1,signal/2,push/3,status/1]).
-export([init/1,handle_call/3,handle_cast/2,handle_info/2,terminate/2,format_status/1]).
-define(PC,'Elixir.ExWebRTC.PeerConnection').
-define(SD,'Elixir.ExWebRTC.SessionDescription').
-define(ICE,'Elixir.ExWebRTC.ICECandidate').
start_link(Args) -> gen_server:start_link(?MODULE,Args,[]).
signal(Pid,P) -> gen_server:cast(Pid,{signal,P}).
push(Pid,H,PCM) -> gen_server:call(Pid,{push,H,PCM},1000).
status(Pid) -> gen_server:call(Pid,status).
init(#{owner := Owner,context := #{deadline := Deadline},role := Role} = Args) ->
    process_flag(trap_exit,true),monitor(process,Owner),
    case maps:find(source_pid,Args) of {ok,Source} -> monitor(process,Source);error -> ok end,
    {ok,_} = application:ensure_all_started(ex_webrtc),
    {ok,PC} = ?PC:start_link([{ice_servers,application:get_env(parvi_transport,native_ice_servers,[])},
                             {video_codecs,[]},{audio_codecs,[]}]),
    monitor(process,PC),erlang:send_after(max(1,Deadline-now_ms()),self(),lease_expired),
    erlang:send_after(10000,self(),setup_timeout),
    S = Args#{pc => PC,channel => undefined,open => false,remote_ready => false,pending_ice => [],
              sequence => 0,last_sequence => undefined,received => 0,sent => 0,rejected => 0},
    case Role of provider -> self() ! offer;receiver -> ok end,
    {ok,S}.
handle_call(status,_,S) -> {reply,maps:with([role,open,received,sent,rejected],S),S};
handle_call({push,H,PCM},{Source,_},#{role := provider,source_pid := Source,open := true,
                                   pc := PC,channel := Ref,descriptor := D,sequence := Seq} = S) ->
    case live(S) andalso below_limit(PC,256) of
        true ->
            case parvi_audio_packet:encode(channel,D,H#{sequence => Seq},PCM) of
                {ok,Packet} ->
                    Reply = ?PC:send_data(PC,Ref,Packet,binary),
                    {reply,Reply,S#{sequence := (Seq+1) band 16#ffffffff,sent := maps:get(sent,S)+1}};
                Error -> {reply,Error,S}
            end;
        false -> {reply,{error,expired_or_busy},S}
    end;
handle_call(_,_,S) -> {reply,{error,media_not_open_or_owner},S}.
handle_cast({signal,P},S) ->
    try live(S) orelse error(expired),incoming_signal(P,S) of
        Next -> {noreply,Next}
    catch _:_ -> {stop,invalid_media_signal,S} end;
handle_cast(_,S) -> {noreply,S}.
handle_info(offer,#{role := provider,pc := PC} = S) ->
    {ok,#{ref := Ref}} = ?PC:create_data_channel(PC,label(S),[{ordered,false},{max_retransmits,0}]),
    {ok,Offer} = ?PC:create_offer(PC),ok = ?PC:set_local_description(PC,Offer),
    notify_signal(#{<<"kind">> => <<"signal.offer">>,<<"sdp">> => maps:get(sdp,Offer)},S),
    {noreply,S#{channel := Ref}};
handle_info({ex_webrtc,PC,{data_channel,#{label := Label,ref := Ref}}},#{pc := PC,role := receiver} = S) ->
    case Label=:=label(S) andalso maps:get(channel,S)=:=undefined of
        true -> {noreply,S#{channel := Ref}};
        false -> ?PC:close_data_channel(PC,Ref),{noreply,S}
    end;
handle_info({ex_webrtc,PC,{data_channel_state_change,Ref,open}},#{pc := PC,channel := Ref} = S) ->
    maps:get(owner,S) ! {audio_transport,self(),open},{noreply,S#{open := true}};
handle_info({ex_webrtc,PC,{data,Ref,Packet}},#{pc := PC,channel := Ref,role := receiver,open := true} = S)
        when is_binary(Packet),byte_size(Packet)=<16384 ->
    case live(S) of
        false -> {stop,normal,S};
        true ->
            case parvi_audio_packet:decode(channel,maps:get(descriptor,S),Packet) of
                {ok,H,PCM} ->
                    Seq = maps:get(sequence,H),Last = maps:get(last_sequence,S),
                    Delta = case Last of undefined -> 1;_ -> (Seq-Last) band 16#ffffffff end,
                    case Delta>0 andalso Delta<16#80000000 of
                        true ->
                            bounded_notify({audio_pcm,self(),H,PCM},S),
                            {noreply,S#{last_sequence := Seq,received := maps:get(received,S)+1}};
                        false -> {noreply,S#{rejected := maps:get(rejected,S)+1}}
                    end;
                _ -> {noreply,S#{rejected := maps:get(rejected,S)+1}}
            end
    end;
handle_info({ex_webrtc,PC,{ice_candidate,C}},#{pc := PC} = S) ->
    J = ?ICE:to_json(C),
    notify_signal(#{<<"kind">> => <<"signal.candidate">>,<<"candidate">> => maps:get(<<"candidate">>,J),
        <<"mid">> => maps:get(<<"sdpMid">>,J),<<"line">> => maps:get(<<"sdpMLineIndex">>,J)},S),{noreply,S};
handle_info({ex_webrtc,PC,{connection_state_change,State}},#{pc := PC} = S)
        when State=:=failed;State=:=closed -> {stop,normal,S};
handle_info({ex_webrtc,PC,{data_channel_state_change,Ref,closed}},#{pc := PC,channel := Ref} = S) -> {stop,normal,S};
handle_info(setup_timeout,#{open := false} = S) -> {stop,setup_timeout,S};
handle_info(lease_expired,S) -> {stop,normal,S};
handle_info({'DOWN',_,process,_,_},S) -> {stop,normal,S};
handle_info({'EXIT',PC,_},#{pc := PC} = S) -> {stop,normal,S};
handle_info(_,S) -> {noreply,S}.
incoming_signal(#{<<"kind">> := <<"signal.offer">>,<<"sdp">> := SDP},#{role := receiver,remote_ready := false,pc := PC} = S) ->
    ok = ?PC:set_remote_description(PC,?SD:from_json(#{<<"type">> => <<"offer">>,<<"sdp">> => SDP})),
    {ok,Answer} = ?PC:create_answer(PC),ok = ?PC:set_local_description(PC,Answer),
    notify_signal(#{<<"kind">> => <<"signal.answer">>,<<"sdp">> => maps:get(sdp,Answer)},S),flush_ice(S);
incoming_signal(#{<<"kind">> := <<"signal.answer">>,<<"sdp">> := SDP},#{role := provider,remote_ready := false,pc := PC} = S) ->
    ok = ?PC:set_remote_description(PC,?SD:from_json(#{<<"type">> => <<"answer">>,<<"sdp">> => SDP})),flush_ice(S);
incoming_signal(#{<<"kind">> := <<"signal.candidate">>,<<"candidate">> := C,<<"mid">> := Mid,<<"line">> := Line},S) ->
    J = #{<<"candidate">> => C,<<"sdpMid">> => Mid,<<"sdpMLineIndex">> => Line},
    case maps:get(remote_ready,S) of
        true -> add_ice(J,S),S;
        false -> L = maps:get(pending_ice,S),true = length(L)<32,S#{pending_ice := [J|L]}
    end.
flush_ice(S) -> [add_ice(C,S) || C <- lists:reverse(maps:get(pending_ice,S))],S#{remote_ready := true,pending_ice := []}.
add_ice(C,#{pc := PC}) -> ok = ?PC:add_ice_candidate(PC,?ICE:from_json(C)).
notify_signal(P,S) -> bounded_notify({audio_signal,self(),P},S).
bounded_notify(Message,#{owner := Owner}) ->
    case process_info(Owner,message_queue_len) of {message_queue_len,N} when N<64 -> Owner ! Message;_ -> ok end.
label(#{subscription := Id,attempt := Attempt}) -> <<"parvi-audio/v2/",Id/binary,"/",Attempt/binary>>.
live(#{context := #{deadline := Deadline}}) -> now_ms()<Deadline.
now_ms() -> erlang:monotonic_time(millisecond).
terminate(_,#{pc := PC}) -> try ?PC:close(PC) catch _:_ -> ok end,ok.

format_status(Status) -> maps:map(fun(state,S) -> maps:with([role,open,received,sent,rejected],S);(log,_) -> [];(_,_) -> redacted end,Status).

below_limit(Pid,Limit) -> case process_info(Pid,message_queue_len) of {message_queue_len,N} -> N<Limit;_ -> false end.
