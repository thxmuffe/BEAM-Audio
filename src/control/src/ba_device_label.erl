%% Display metadata only: never used for identity, routing or admission.
-module(ba_device_label).
-export([local/1,format/3]).
local(Instance) ->
    format(unicode:characters_to_binary(os:getenv("BA_DEVICE_NAME","Device")),
           application:get_env(ba_device_web,origin,<<>>),Instance).
format(Name,Origin,Instance) ->
    %% Bound UTF-8 labels to the existing 256-byte capability field.
    Text=unicode:characters_to_list(Name),
    Clean=unicode:characters_to_binary([case C<32 orelse C=:=127 of true -> 32;false -> C end || C <- lists:sublist(Text,48)]),
    Web=case Origin of
        <<"http://127.0.0.1:",Port/binary>> -> <<" | Web | ",Port/binary>>;
        _ -> <<>>
    end,
    Short=binary:part(Instance,0,min(8,byte_size(Instance))),
    <<Clean/binary,Web/binary," | ",Short/binary>>.
