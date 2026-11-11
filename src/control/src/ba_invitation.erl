%% Versioned invitations: legacy local credentials or scoped relay capabilities.
-module(ba_invitation).
-export([format/2, relay/3, parse/1]).

relay(Buffee, Token, Mailbox) ->
    Query = uri_string:compose_query([{<<"desk">>, ba_relay:url()},
        {<<"node">>, ba_relay:id()}, {<<"mailbox">>, Mailbox},
        {<<"buffee">>, Buffee}, {<<"token">>, Token}]),
    <<"beamaudio://buffee/v2?", Query/binary>>.

format(Buffee, Token) ->
    Query = uri_string:compose_query([{<<"node">>, atom_to_binary(node())},
        {<<"cookie">>, atom_to_binary(erlang:get_cookie())},
        {<<"buffee">>, Buffee}, {<<"token">>, Token}]),
    <<"beamaudio://buffee/v1?", Query/binary>>.

parse(Input) when is_binary(Input), byte_size(Input) =< 2048 ->
    try
        #{scheme := Scheme, host := <<"buffee">>, path := Path, query := Query} =
            URI = uri_string:parse(string:trim(Input)),
        true = Scheme =:= <<"beamaudio">>,
        4 = map_size(URI),
        parse_query(Path, lists:sort(uri_string:dissect_query(Query)))
    catch _:_ -> {error, invalid_invitation} end;
parse(_) -> {error, invalid_invitation}.

parse_query(<<"/v1">>, Fields) ->
        [{<<"buffee">>, Buffee}, {<<"cookie">>, Cookie}, {<<"node">>, Node}, {<<"token">>, Token}] =
            Fields,
        {ok, _} = ba_legacy_connection:parse(ba_legacy_connection:format(Node, Cookie)),
        true = valid_id(Buffee) andalso valid_id(Token),
        {ok, #{node => Node, cookie => Cookie, buffee => Buffee, token => Token}};
parse_query(<<"/v2">>, [{<<"buffee">>, Buffee}, {<<"desk">>, Desk}, {<<"mailbox">>, Cap},
                         {<<"node">>, Node}, {<<"token">>, Token}]) ->
    true = ba_relay:valid_url(Desk) andalso ba_buffee_wire:hex(Node, 64) andalso
           valid_id(Cap) andalso valid_id(Buffee) andalso valid_id(Token),
    {ok, #{desk => Desk, mailbox => Cap, node => Node, buffee => Buffee, token => Token}}.

valid_id(Id) when is_binary(Id), byte_size(Id) =:= 32 ->
    re:run(Id, <<"^[0-9A-F]{32}$">>, [{capture, none}]) =:= match;
valid_id(_) -> false.
