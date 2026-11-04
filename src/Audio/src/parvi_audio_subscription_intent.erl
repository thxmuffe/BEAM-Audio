%% Durable user intent only: never persist media buffers, PIDs or packet targets.
-module(parvi_audio_subscription_intent).
-export([load/0, save/1, new/4, matches/3, clock_ready/2]).

load() ->
    case parvi_cluster_store:load(audio_subscription,undefined) of
        #{cluster := C,node := N,source_key := K,name := Name,profile := P,playing := B} = I
                when is_binary(C),is_binary(N),is_binary(K),is_binary(Name),
                     (P =:= channel orelse P =:= point),is_boolean(B) -> I;
        _ -> undefined
    end.
save(Intent) -> parvi_cluster_store:save(audio_subscription,Intent).
new(Cluster,Node,#{name := Name} = Offer,Profile) ->
    #{cluster => Cluster,node => Node,source_key => maps:get(source_key,Offer,Name),
      name => Name,profile => Profile,playing => false}.
matches(#{node := Node,source_key := Key,profile := Profile},Node,
        #{name := Name,profiles := Profiles} = Offer) ->
    maps:get(source_key,Offer,Name) =:= Key andalso maps:is_key(Profile,Profiles);
matches(_,_,_) -> false.

%% A follower must have acquired a recent sample, including one after resume.
%% A master owns the local reference even when some cluster members are offline.
clock_ready(#{role := master,filtered_utc_time := UTC},_) when is_integer(UTC) -> true;
clock_ready(#{filter_ready := true,last_sync := Sync,age_ns := Age},After)
        when is_integer(Sync),is_integer(Age),Age =< 10000000000 ->
    After =:= undefined orelse Sync >= After;
clock_ready(_,_) -> false.
