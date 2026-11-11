%% Declarative collection only. No transports, incarnations, packets or leases.
-module(ba_subscription).
-export([load/0,save/1,new/4,matches/3,clock_ready/2]).
load() ->
    case ba_device_store:load(audio_subscriptions,undefined) of
        undefined -> #{};
        #{format := 1,subscriptions := Items} -> validate(Items),Items;
        _ -> error(unsupported_audio_subscriptions)
    end.
save(Items) -> validate(Items),ba_device_store:save(audio_subscriptions,#{format => 1,subscriptions => Items}).
new(Buffee,Device,#{name := Name,source_key := Key},channel) ->
    #{id => binary:encode_hex(crypto:strong_rand_bytes(16)),buffee => Buffee,device => Device,
      source_key => Key,name => Name,profile => channel,playing => false,gain => 1.0}.
matches(#{device := Device,source_key := Key,profile := channel},Device,
        #{source_key := Key,profiles := #{channel := _}}) -> true;
matches(_,_,_) -> false.
validate(Items) ->
    true = is_map(Items) andalso map_size(Items) =< 16,
    maps:foreach(fun(Id,I) ->
        [buffee,device,gain,id,name,playing,profile,source_key] = lists:sort(maps:keys(I)),
        Id = maps:get(id,I),true = ba_buffee_job:hex(Id,32),
        true = ba_buffee_job:hex(maps:get(buffee,I),32),
        true = ba_buffee_job:hex(maps:get(device,I),64),
        [begin B = maps:get(K,I),true = is_binary(B) andalso byte_size(B)>0 andalso byte_size(B)=<128 end
            || K <- [name,source_key]],
        channel = maps:get(profile,I),true = is_boolean(maps:get(playing,I)),
        G = maps:get(gain,I),true = is_number(G) andalso G>=0 andalso G=<1
    end,Items),ok.
clock_ready(#{state := synchronized,role := master,filtered_utc_time := UTC,last_sync := Sync},After)
        when is_integer(UTC),is_integer(Sync) -> After=:=undefined orelse Sync>=After;
clock_ready(#{state := synchronized,filter_ready := true,last_sync := Sync,age_ns := Age},After)
        when is_integer(Sync),is_integer(Age),Age >= 0,Age =< 10000000000 ->
    After =:= undefined orelse Sync >= After;
clock_ready(_,_) -> false.
