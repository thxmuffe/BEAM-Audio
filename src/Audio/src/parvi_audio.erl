%% Local publication API. Remote discovery/subscription belongs to Swarm control.
-module(parvi_audio).
-export([publish/1,publish/2,unpublish/1,pause/2,sources/0,describe/1,watch_sources/0,
         subscribe/2,ready/1,close/1,status/1,sessions/0,push/4,listen/2,
         validate_offer/1,validate_request/2,handler/0,backend/0]).
publish(Offer) -> publish(Offer,self()).
publish(Offer0,undefined) -> publish(Offer0,self());
publish(Offer0,Owner) when is_pid(Owner),node(Owner)=:=node() ->
    Offer = case maps:is_key(source_key,Offer0) of
        true -> Offer0;false -> Offer0#{source_key => maps:get(name,Offer0,<<>>)}
    end,
    case validate_offer(Offer) of
        ok -> with_runtime(fun() ->
            case parvi_audio_sup:start_source({Offer,Owner}) of
                {ok,Pid} ->
                    case parvi_audio_receiver:register_source(Pid) of
                        ok -> {ok,Pid};Error -> gen_server:stop(Pid),Error
                    end;
                Error -> Error
            end
        end);
        Error -> Error
    end.
unpublish(Source) when node(Source)=:=node() -> gen_server:stop(Source).
pause(Source,B) when node(Source)=:=node(),is_boolean(B) -> gen_server:call(Source,{pause,B}).
sources() ->
    case whereis(parvi_audio_sup) of undefined -> [];_ ->
        [P || {{source,_},P,_,_} <- supervisor:which_children(parvi_audio_sup),is_pid(P)] end.
describe(Source) when is_pid(Source),node(Source)=:=node() -> gen_server:call(Source,describe).
watch_sources() -> {error,use_swarm_catalogue}.
sessions() -> parvi_audio_sup:sessions().
handler() -> (parvi_audio_stream_handler_legacy:info())#{transport => <<"scoped_webrtc_datachannel">>}.
backend() -> handler().
status(Session) when node(Session)=:=node() -> parvi_audio_subscription:status(Session).
push(Source,Profile,Header,PCM) when node(Source)=:=node() -> gen_server:call(Source,{push,Profile,Header,PCM}).
subscribe(_,_) -> {error,use_publisher_and_source_subscription}.
ready(_) -> {error,subscription_owner_controls_setup}.
close(Session) when node(Session)=:=node() -> gen_server:stop(Session).
listen(_,_) -> {error,subscription_owner_controls_consumer}.
with_runtime(Fun) -> case parvi_audio_sup:ensure_started() of ok -> Fun();Error -> Error end.
validate_offer(#{name := Name,source_key := Key,profiles := #{channel := D} = Profiles})
        when is_binary(Name),byte_size(Name)>0,byte_size(Name)=<128,
             is_binary(Key),byte_size(Key)>0,byte_size(Key)=<128,map_size(Profiles)=:=1 ->
    case parvi_audio_packet:validate_descriptor(channel,D) of
        ok ->
            case D of
                #{encoding := pcm,channel_count := C,sample_rate := R} when (C=:=1 orelse C=:=2),R>=8000,R=<192000 -> ok;
                _ -> {error,unsupported_collection_format}
            end;
        _ -> {error,unsupported_collection_format}
    end;
validate_offer(_) -> {error,invalid_offer}.
validate_request(#{profile := channel,selector := all},#{profiles := #{channel := D}}) -> {ok,D};
validate_request(_,_) -> {error,invalid_request}.
