-module(parvi_cluster_store_tests).
-include_lib("eunit/include/eunit.hrl").

old_relationships_are_forgotten_identity_is_retained_test() ->
    Dir = filename:join("/tmp","parvi-state-reset-"++integer_to_list(erlang:unique_integer([positive]))),
    Saved = [{K,os:getenv(K)} || K <- ["PARVI_STATE_DIR","PARVI_IDENTITY_SEED"]],
    Names = [policy,authority,desk,audio_subscription],
    try
        os:putenv("PARVI_STATE_DIR",Dir),
        os:putenv("PARVI_IDENTITY_SEED",binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(32)))),
        Identity = parvi_cluster_store:identity(),
        ok = filelib:ensure_dir(filename:join(Dir,"state")),
        [begin
            Path = filename:join(Dir,atom_to_list(Name)++".term"),
            ok = file:write_file(Path,term_to_binary(#{version => 1,data => old_relationship})),
            ?assertEqual(undefined,parvi_cluster_store:load(Name,undefined)),
            ok = parvi_cluster_store:save(Name,fresh_relationship),
            ?assertEqual(fresh_relationship,parvi_cluster_store:load(Name,undefined))
        end || Name <- Names],
        ?assertEqual(Identity,parvi_cluster_store:identity()),
        ok = file:write_file(filename:join(Dir,"policy.term"),term_to_binary(#{version => 99,data => invalid})),
        ?assertError({unsupported_cluster_state,policy},parvi_cluster_store:load(policy,undefined))
    after
        [case V of false -> os:unsetenv(K); _ -> os:putenv(K,V) end || {K,V} <- Saved],
        [file:delete(filename:join(Dir,atom_to_list(N)++".term")) || N <- Names],
        file:del_dir(Dir)
    end.
