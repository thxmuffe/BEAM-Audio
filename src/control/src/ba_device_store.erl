%% Small local checkpoints, owned by the worker writing each record.
%% Private identity material is supplied by the platform Keychain, never stored here.
-module(ba_device_store).
-export([identity/0, load/2, save/2,forget_session/1]).

%% This Device's key pair, from the seed its launcher supplies (BA_IDENTITY_SEED).
identity() ->
    Hex = ba_settings:env("BA_IDENTITY_SEED"),
    Seed = binary:decode_hex(list_to_binary(Hex)),
    32 = byte_size(Seed),
    crypto:generate_key(eddsa, ed25519, Seed).

load(Name, Default) ->
    case transient(Name) of
        true ->
            try ets:lookup(ba_session_scope:table(ba_session_state),Name) of [{_,Data}] -> Data;[] -> Default
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
                    case decode(Name, Bytes) of
                        stale -> Default;
                        #{version := 2, data := Data} -> Data;
                        %% User-requested clean start for the Session migration.
                        %% Device identity is held separately in secure storage.
                        #{version := 1} -> Default;
                        _ -> error({unsupported_device_state,Name})
                    end;
                {error, Reason} -> error({device_state_read_failed, Name, Reason})
            end
    end.
%% A saved Session record from an older build may name things this build no
%% longer has (e.g. `recover_authority`), which [safe] refuses. Old records are
%% intentionally dropped (see the 2026-11-17 join model), so it starts empty
%% instead of stopping the whole runtime. Other records still fail loudly.
decode(Name, Bytes) ->
    try binary_to_term(Bytes, [safe])
    catch error:badarg when Name =:= session_connection ->
        logger:warning("Ignoring an unreadable or outdated saved Session record."),
        stale
    end.

save(Name, Data) ->
    case transient(Name) of
        true -> ets:insert(ba_session_scope:table(ba_session_state),{Name,Data}),ok;
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

%% Called by the Session owner after stopping its workers, or for a closed
%% scope. Forget discards both the return link and the accepted privilege policy.
forget_session(Session) ->
    Saved=load(saved_sessions,#{}),
    case maps:is_key(Session,Saved) of
        true -> ok=save(saved_sessions,maps:remove(Session,Saved));
        false -> ok
    end,
    case load(session_connection,undefined) of
        #{session := Session} -> save(session_connection,undefined);
        _ -> ok
    end.

path(Name) ->
    case ba_session_scope:state_directory(Name) of
        false -> undefined; % Existing command-line/probe profiles remain ephemeral.
        Directory ->
            %% Never persist membership under an identity that cannot be restored.
            true = ba_settings:env("BA_IDENTITY_SEED") =/= false,
            filename:join(Directory, atom_to_list(Name) ++ ".term")
    end.

%% Live records never read/write device files, including old Session snapshots.
transient(Name) ->
    lists:member(Name,[session_authority,session_member,session_desks,session_time_policy,
                      session_time_cache,audio_subscriptions,session_exclusions]).
