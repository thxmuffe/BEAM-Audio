%% A portable UI format, not a replacement for Erlang's authentication cookie.
-module(parvi_connection).
-export([local/0, format/2, parse/1]).

local() -> format(atom_to_binary(node()), atom_to_binary(erlang:get_cookie())).

format(Node, Cookie) when is_binary(Node), is_binary(Cookie) ->
    Query = uri_string:compose_query([{<<"node">>, Node}, {<<"cookie">>, Cookie}]),
    <<"parvi://connect/v1?", Query/binary>>.

parse(Input) when is_binary(Input), byte_size(Input) =< 2048 ->
    try
        #{scheme := <<"parvi">>, host := <<"connect">>, path := <<"/v1">>,
          query := Query} = URI = uri_string:parse(string:trim(Input)),
        4 = map_size(URI),
        [{<<"cookie">>, Cookie}, {<<"node">>, Node}] =
            lists:sort(uri_string:dissect_query(Query)),
        true = valid(Node) andalso valid(Cookie),
        {ok, #{node => Node, cookie => Cookie}}
    catch _:_ -> {error, invalid_connection_string} end;
parse(_) -> {error, invalid_connection_string}.

valid(Value) when is_binary(Value), byte_size(Value) > 0, byte_size(Value) =< 128 ->
    case unicode:characters_to_binary(Value, utf8, utf8) of
        Value -> re:run(Value, <<"[\\x00-\\x20\\x7f]">>, [{capture, none}]) =:= nomatch;
        _ -> false
    end;
valid(_) -> false.
