%% Private capabilities and bounded logs use the receiving Device approval pipeline.
%% Only named diagnostic files; never arbitrary paths, identity or settings files.
-module(ba_inspection).
-include_lib("kernel/include/file.hrl").
-export([capabilities/2,read/2,chunk_size/0,validate_request/1,validate_reply/1,error/1]).
-define(MAX,8192).
chunk_size() -> ?MAX.
%% Local and remote inspection share one approval decision; public capabilities
%% remain available without Inspect consent.
capabilities(false,_) -> {ok,ba_device_handler:capabilities(false)};
capabilities(true,Requester) ->
    case ba_device_request:approve(inspect,Requester) of
        ok when Requester=:=<<"local">> -> {ok,ba_device_handler:capabilities(true)};
        ok ->
            Caps=ba_device_handler:capabilities(true),
            case maps:find(<<"audio">>,Caps) of
                {ok,Rows} -> {ok,Caps#{<<"audio">> := maps:map(fun(_,Row) ->
                    maps:without([<<"peak_db">>,<<"rms_db">>,<<"meter_age_ms">>,<<"meter_stage">>],Row)
                end,Rows)}};
                error -> {ok,Caps}
            end;
        Error -> Error
    end.
validate_request(P) ->
    ba_session_passport:exact(P,[<<"log">>,<<"offset">>,<<"length">>]++
        case maps:is_key(<<"version">>,P) of true -> [<<"version">>];false -> [] end),
    true=lists:member(maps:get(<<"log">>,P),logs()),
    true=uint(maps:get(<<"offset">>,P)),
    N=maps:get(<<"length">>,P),true=is_integer(N) andalso N>0 andalso N=< ?MAX,
    case maps:find(<<"version">>,P) of {ok,V} -> version(V);error -> ok end,ok.
validate_reply(P) ->
    ba_session_passport:exact(P,[<<"data">>,<<"next">>,<<"size">>,<<"version">>,<<"eof">>]),
    B=maps:get(<<"data">>,P),true=is_binary(B) andalso byte_size(B)=<4*((?MAX+2) div 3),
    true=byte_size(base64:decode(B))=< ?MAX,
    true=uint(maps:get(<<"next">>,P)),true=uint(maps:get(<<"size">>,P)),
    version(maps:get(<<"version">>,P)),true=is_boolean(maps:get(<<"eof">>,P)),ok.
version(V) -> true=is_binary(V) andalso byte_size(V)>0 andalso byte_size(V)=<32,ok.
uint(N) -> is_integer(N) andalso N>=0 andalso N=<9007199254740991.
logs() -> [<<"runtime.log">>,<<"runtime.log.0">>,<<"runtime.log.1">>,<<"runtime.log.2">>,
           <<"audio-engine-crash.txt">>].
error(R) -> lists:member(R,[<<"forbidden">>,<<"refused">>,<<"waiting_for_approval">>,<<"declined">>,
                          <<"unavailable">>,<<"log_rotated">>]).
read(P,Requester) ->
    ok=validate_request(P),
    case ba_device_request:approve(inspect,Requester) of
        ok -> read_log(P);
        Error -> Error
    end.
read_log(#{<<"log">> := Name}=P) ->
    case ba_settings:env("BA_STATE_DIR") of
        false -> {error,unavailable};
        Dir ->
            case file:open(filename:join(Dir,binary_to_list(Name)),[read,binary,raw]) of
                {ok,F} -> try chunk(F,P) after file:close(F) end;
                _ -> {error,unavailable}
            end
    end.
chunk(F,#{<<"offset">> := Offset,<<"length">> := Length}=P) ->
    case file:read_file_info(F) of
        {ok,#file_info{type=regular,size=Size,inode=Inode}} ->
            Version=integer_to_binary(Inode),
            case maps:get(<<"version">>,P,Version)=:=Version andalso Offset=<Size of
                false -> {error,log_rotated};
                true ->
                    case file:pread(F,Offset,Length) of
                        {ok,Data} -> reply(Data,Offset,Size,Version);
                        eof -> reply(<<>>,Offset,Size,Version);
                        _ -> {error,unavailable}
                    end
            end;
        _ -> {error,unavailable}
    end.
reply(Data,Offset,Size,Version) ->
    Next=Offset+byte_size(Data),
    {ok,#{<<"data">> => base64:encode(Data),<<"next">> => Next,<<"size">> => Size,
          <<"version">> => Version,<<"eof">> => Next>=Size}}.
