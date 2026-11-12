%% Small local checkpoints, owned by the worker writing each record.
%% Private identity material is supplied by the platform Keychain, never stored here.
-module(ba_device_store).
-export([identity/0, node_name/1, load/2, save/2]).

identity() ->
    case os:getenv("BA_IDENTITY_SEED") of
        false -> crypto:generate_key(eddsa, ed25519);
        Hex ->
            Seed = binary:decode_hex(list_to_binary(Hex)),
            32 = byte_size(Seed),
            crypto:generate_key(eddsa, ed25519, Seed)
    end.

node_name(Platform) ->
    {Public, _} = identity(),
    binary_to_atom(<<"ba_", Platform/binary, "_", (binary:encode_hex(Public))/binary,
                     "@127.0.0.1">>).

load(Name, Default) ->
    case transient(Name) of
        true ->
            try ets:lookup(ba_session_scope:table(ba_buffee_state),Name) of [{_,Data}] -> Data;[] -> Default
            catch error:badarg -> Default end;
        false -> load_file(Name,Default)
    end.
load_file(Name,Default) ->
    case path(Name) of
        undefined -> Default;
        Path ->
            case file:read_file(Path) of
                {error, enoent} -> Default;
                {ok, Bytes} ->
                    case binary_to_term(Bytes, [safe]) of
                        #{version := 2, data := Data} -> Data;
                        %% User-requested clean start for the Buffee migration.
                        %% Device identity is held separately in secure storage.
                        #{version := 1} -> Default;
                        _ -> error({unsupported_device_state,Name})
                    end;
                {error, Reason} -> error({device_state_read_failed, Name, Reason})
            end
    end.

save(Name, Data) ->
    case transient(Name) of
        true -> ets:insert(ba_session_scope:table(ba_buffee_state),{Name,Data}),ok;
        false -> save_file(Name,Data)
    end.
save_file(Name,Data) ->
    case path(Name) of
        undefined -> ok;
        Path ->
            ok = filelib:ensure_dir(Path),
            Temp = Path ++ ".tmp",
            {ok, File} = file:open(Temp, [write, binary, raw]),
            try
                ok = file:change_mode(Temp, 8#600),
                ok = file:write(File, term_to_binary(#{version => 2, data => Data})),
                ok = file:sync(File)
            after
                ok = file:close(File)
            end,
            ok = file:rename(Temp, Path)
    end.

path(Name) ->
    case ba_session_scope:state_directory(Name) of
        false -> undefined; % Existing command-line/probe profiles remain ephemeral.
        Directory ->
            %% Never persist membership under an identity that cannot be restored.
            true = os:getenv("BA_IDENTITY_SEED") =/= false,
            filename:join(Directory, atom_to_list(Name) ++ ".term")
    end.

%% Live records never read/write device files, including old Buffee snapshots.
transient(Name) ->
    application:get_env(ba_core,runtime_profile,legacy_apps)=:=buffee_control andalso
    lists:member(Name,[buffee_authority,buffee_member,buffee_desks,buffee_time_policy,
                      buffee_time_cache,audio_subscriptions,buffee_exclusions]).
