%% Local CLI process records and persistent identity, never saved Swarm state.
-module(ba_cli_store).
-include_lib("kernel/include/file.hrl").
-export([home/0,dir/1,private_dir/1,identity/1,read/1,write/2,remove/1,names/0,valid_name/1,reserve/3]).
home() -> case os:getenv("BA_CLI_HOME") of false -> filename:join(filename:basedir(user_data,"beam-audio"),"devices");P -> filename:absname(P) end.
valid_name(N) -> re:run(N,"^[A-Za-z0-9][A-Za-z0-9_-]{0,47}$",[{capture,none}])=:=match.
dir(N) -> case valid_name(N) of true -> filename:join(home(),N);false -> error(invalid_device_name) end.
private_dir(D) ->
    ok=filelib:ensure_dir(filename:join(D,"placeholder")),
    case file:read_link_info(D) of {ok,#file_info{type=directory}} -> ok=file:change_mode(D,8#700);_ -> error(unsafe_state_directory) end.
identity(D) ->
    File=filename:join(D,"identity.seed"),
    case file:open(File,[write,binary,exclusive]) of
        {ok,F} -> ok=file:change_mode(File,8#600),Seed=crypto:strong_rand_bytes(32),ok=file:write(F,Seed),ok=file:close(F);
        {error,eexist} -> ok;
        {error,R} -> error({identity_file,R})
    end,
    {ok,#file_info{type=regular,mode=Mode}}=file:read_link_info(File),
    true=Mode band 8#077=:=0,
    {ok,<<Seed0:32/binary>>}=file:read_file(File),binary:encode_hex(Seed0).
read(N) ->
    case file:read_file(filename:join(dir(N),"running.json")) of
        {ok,B} -> try {ok,json:decode(B)} catch _:_ -> {error,invalid_process_record} end;
        {error,enoent} -> {error,not_running};
        {error,R} -> {error,R}
    end.
write(Path,Map) ->
    case file:open(Path,[write,binary,exclusive]) of
        {ok,F} -> ok=file:change_mode(Path,8#600),
            try file:write(F,json:encode(Map)) after file:close(F) end;
        Error -> Error
    end.
remove(Path) -> case file:delete(Path) of ok -> ok;{error,enoent} -> ok;E -> E end.
names() -> case file:list_dir(home()) of {ok,Ns} -> lists:sort([N || N <- Ns,valid_name(N),filelib:is_file(filename:join(dir(N),"running.json"))]);_ -> [] end.

%% Atomic local runtime allocation. An existing (even stale) record is never
%% overwritten; explicit names retain their original single-runtime semantics.
reserve(Base,Next,Record) -> reserve(Base,Next,Record,1).
reserve(_,_,_,N) when N>100 -> {error,no_free_instance};
reserve(Base,Next,Record,N) ->
    Name=case N of 1 -> Base;_ -> lists:sublist(Base,40)++"-"++integer_to_list(N) end,
    D=dir(Name),ok=private_dir(home()),ok=private_dir(D),
    Path=filename:join(D,"running.json"),
    case write(Path,Record#{name => list_to_binary(Name)}) of
        ok -> {ok,Name,D};
        {error,eexist} when Next -> reserve(Base,Next,Record,N+1);
        {error,eexist} -> {error,already_running};
        Error -> Error
    end.
