%% Small local checkpoints, owned by the worker writing each record.
%% Private identity material is supplied by the platform Keychain, never stored here.
-module(parvi_cluster_store).
-export([identity/0, node_name/1, load/2, save/2]).

identity() ->
    case os:getenv("PARVI_IDENTITY_SEED") of
        false -> crypto:generate_key(eddsa, ed25519);
        Hex ->
            Seed = binary:decode_hex(list_to_binary(Hex)),
            32 = byte_size(Seed),
            crypto:generate_key(eddsa, ed25519, Seed)
    end.

node_name(Platform) ->
    {Public, _} = identity(),
    binary_to_atom(<<"parvi_", Platform/binary, "_", (binary:encode_hex(Public))/binary,
                     "@127.0.0.1">>).

load(Name, Default) ->
    case path(Name) of
        undefined -> Default;
        Path ->
            case file:read_file(Path) of
                {error, enoent} -> Default;
                {ok, Bytes} ->
                    case binary_to_term(Bytes, [safe]) of
                        #{version := 2, data := Data} -> Data;
                        %% User-requested clean start for the Swarm migration.
                        %% Device identity is held separately in secure storage.
                        #{version := 1} -> Default;
                        _ -> error({unsupported_cluster_state,Name})
                    end;
                {error, Reason} -> error({cluster_state_read_failed, Name, Reason})
            end
    end.

save(Name, Data) ->
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
    case os:getenv("PARVI_STATE_DIR") of
        false -> undefined; % Existing command-line/probe profiles remain ephemeral.
        Directory ->
            %% Never persist membership under an identity that cannot be restored.
            true = os:getenv("PARVI_IDENTITY_SEED") =/= false,
            filename:join(Directory, atom_to_list(Name) ++ ".term")
    end.
