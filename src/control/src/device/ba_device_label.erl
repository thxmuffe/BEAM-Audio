%% Display metadata only: never used for identity, routing or admission.
-module(ba_device_label).
-export([local/1,format/3,os_name/0,display/1]).
-ifdef(TEST).
-export([family_type/1]).
-endif.
local(Instance) ->
    Name=display(unicode:characters_to_binary(ba_settings:env("BA_DEVICE_NAME",os_name()))),
    Label=case ba_settings:app(session_observer,false) of true -> <<"Inspector ",Name/binary>>;false -> Name end,
    %% "Web" marks a Device people open in a browser. A native app host that
    %% merely draws the same UI in its own window sets BA_NATIVE_APP=1.
    Origin=case ba_settings:env("BA_NATIVE_APP") of
        "1" -> <<>>;
        _ -> persistent_term:get({ba_device_web,origin},<<>>)
    end,
    format(Label,Origin,Instance).
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
    case ba_settings:env("BA_DEVICE_NAME") of
        false -> case ba_settings:env("BA_PLATFORM") of
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
    Type=case ba_settings:env("BA_PLATFORM") of
        "ios" -> <<"iPhone">>;
        "mac" -> <<"Mac">>;
        "windows" -> windows_type();
        _ -> case os:type() of {unix,darwin} -> <<"Mac">>;{win32,_} -> windows_type();_ -> <<"Linux">> end
    end,
    <<Type/binary," | ",Name/binary>>.

%% A PC's product family ("ThinkPad E14 Gen 3" -> "ThinkPad") reads better than
%% "Windows". Read once per VM from the BIOS description; OEM placeholders fall
%% back to "Windows".
windows_type() ->
    case persistent_term:get({?MODULE,windows_type},undefined) of
        undefined ->
            Type=try family_type(os:cmd("reg query HKLM\\HARDWARE\\DESCRIPTION\\System\\BIOS /v SystemFamily"))
                 catch _:_ -> <<"Windows">> end,
            persistent_term:put({?MODULE,windows_type},Type),Type;
        Type -> Type
    end.
family_type(Output) ->
    case re:run(Output,"SystemFamily\\s+REG_SZ\\s+([A-Za-z][A-Za-z0-9-]{2,23})",[{capture,all_but_first,binary}]) of
        {match,[Word]} ->
            case lists:member(string:lowercase(Word),[<<"default">>,<<"system">>,<<"none">>,<<"not">>,<<"type">>,<<"oem">>,<<"to">>,<<"undefined">>]) of
                true -> <<"Windows">>;
                false -> Word
            end;
        _ -> <<"Windows">>
    end.
