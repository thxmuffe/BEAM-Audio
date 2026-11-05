#!/usr/bin/env escript
%% Static BEAM import/export validation; this does not load target NIFs.
main([Root]) ->
    Files = lists:usort(filelib:wildcard(filename:join(Root,"lib/*/ebin/*.beam")) ++
        filelib:wildcard(filename:join(Root,"native_lib/*/ebin/*.beam"))),
    Exports = maps:from_list([begin {ok,{M,[{exports,E}]}}=beam_lib:chunks(P,[exports]),{M,E} end || P <- Files]),
    Core = filelib:wildcard(filename:join(Root,"lib/parvi-*/ebin/*.beam")),
    case Core of [] -> io:format(standard_error,"No core BEAM modules under ~s~n",[Root]),halt(2); _ -> ok end,
    Imports = lists:usort(lists:flatmap(fun(P) -> {ok,{_,[{imports,I}]}}=beam_lib:chunks(P,[imports]),I end,Core)),
    Missing = [{M,F,A} || {M,F,A} <- Imports, not lists:member({F,A},maps:get(M,Exports,[])),
        not (code:which(M) =:= preloaded andalso erlang:function_exported(M,F,A))],
    io:format("~s: ~B core modules, ~B unique imports, ~B unresolved: ~p~n",[Root,length(Core),length(Imports),length(Missing),Missing]),
    case Missing of [] -> ok; _ -> halt(1) end;
main(_) -> io:format(standard_error,"Usage: escript scripts/check-runtime-calls.escript RUNTIME_ROOT~n",[]),halt(2).
