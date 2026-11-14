%% Display metadata only: never used for identity, routing or admission.
-module(ba_device_label).
-export([local/1,format/3,os_name/0,display/1]).
local(Instance) ->
    format(display(unicode:characters_to_binary(os:getenv("BA_DEVICE_NAME",os_name()))),
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

%% Resolve display metadata at startup; never use a hardware name as identity.
os_name() ->
    case os:getenv("BA_DEVICE_NAME") of
        false -> case os:getenv("BA_PLATFORM") of
            "ios" -> "iPhone"; % iOS has no desktop subprocess/hostname dependency.
            _ -> desktop_name()
        end;
        Name -> Name
    end.
desktop_name() ->
    Host=case inet:gethostname() of {ok,H} -> H;_ -> "Device" end,
    case os:type() of
        {unix,darwin} -> case string:trim(os:cmd("/usr/sbin/scutil --get ComputerName 2>/dev/null")) of
            [] -> Host;Name -> Name end;
        {win32,_} -> os:getenv("COMPUTERNAME",Host);
        _ -> Host
    end.

%% Human-readable type and OS name; the signing key remains the identity.
display(Name) ->
    Type=case os:getenv("BA_PLATFORM") of
        "ios" -> <<"iPhone">>;
        "mac" -> <<"Mac">>;
        "windows" -> <<"Windows">>;
        _ -> case os:type() of {unix,darwin} -> <<"Mac">>;{win32,_} -> <<"Windows">>;_ -> <<"Linux">> end
    end,
    <<Type/binary," | ",Name/binary>>.
