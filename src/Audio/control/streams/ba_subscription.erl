%% Declarative collection only. No transports, incarnations, packets or leases.
-module(ba_subscription).
-export([load/0,save/1,new/4,clock_ready/2]).
load() ->
    case ba_device_store:load(audio_subscriptions,undefined) of
        undefined -> #{};
        #{format := 1,subscriptions := Items} -> validate(Items),Items;
        _ -> error(unsupported_audio_subscriptions)
    end.
save(Items) -> validate(Items),ba_device_store:save(audio_subscriptions,#{format => 1,subscriptions => Items}).
new(Session,Device,#{name := Name,source_key := Key},channel) ->
    #{id => binary:encode_hex(crypto:strong_rand_bytes(16)),session => Session,device => Device,
      source_key => Key,name => Name,profile => channel,playing => false}.
validate(Items) ->
    true = is_map(Items) andalso map_size(Items) =< 16,
    maps:foreach(fun(Id,I) ->
        [device,id,name,playing,profile,session,source_key] = lists:sort(maps:keys(I)),
        Id = maps:get(id,I),true = ba_hex:valid(Id,32),
        true = ba_hex:valid(maps:get(session,I),32),
        true = ba_hex:valid(maps:get(device,I),64),
        [begin B = maps:get(K,I),true = is_binary(B) andalso byte_size(B)>0 andalso byte_size(B)=<128 end
            || K <- [name,source_key]],
        channel = maps:get(profile,I),true = is_boolean(maps:get(playing,I))
    end,Items),ok.
%% After a resume, the clock must have read UTC again (resume re-reads at once).
clock_ready(#{state := synchronized,last_sync := Sync},After) when is_integer(Sync) ->
    After =:= undefined orelse Sync >= After;
clock_ready(_,_) -> false.
