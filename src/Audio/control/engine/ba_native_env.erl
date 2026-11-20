%% Explicit child-environment removals; never log or forward signing material.
-module(ba_native_env).
-export([without_secrets/0]).
without_secrets() -> [{"BA_IDENTITY_SEED",false}].
