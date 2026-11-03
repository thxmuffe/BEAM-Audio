%% Versioned invitations: legacy local credentials or scoped relay capabilities.
-module(parvi_invitation).
-export([format/2, relay/3, parse/1]).

relay(Swarm, Token, Mailbox) ->
    Query = uri_string:compose_query([{<<"desk">>, parvi_relay:url()},
        {<<"node">>, parvi_relay:id()}, {<<"mailbox">>, Mailbox},
        {<<"swarm">>, Swarm}, {<<"token">>, Token}]),
    <<"parvi://swarm/v2?", Query/binary>>.

format(Swarm, Token) ->
    Query = uri_string:compose_query([{<<"node">>, atom_to_binary(node())},
        {<<"cookie">>, atom_to_binary(erlang:get_cookie())},
        {<<"swarm">>, Swarm}, {<<"token">>, Token}]),
    <<"parvi://swarm/v1?", Query/binary>>.

parse(Input) when is_binary(Input), byte_size(Input) =< 2048 ->
    try
        #{scheme := <<"parvi">>, host := <<"swarm">>, path := Path, query := Query} =
            URI = uri_string:parse(string:trim(Input)),
        4 = map_size(URI),
        parse_query(Path, lists:sort(uri_string:dissect_query(Query)))
    catch _:_ -> {error, invalid_invitation} end;
parse(_) -> {error, invalid_invitation}.

parse_query(<<"/v1">>, Fields) ->
        [{<<"cookie">>, Cookie}, {<<"node">>, Node}, {<<"swarm">>, Swarm}, {<<"token">>, Token}] =
            Fields,
        {ok, _} = parvi_connection:parse(parvi_connection:format(Node, Cookie)),
        true = valid_id(Swarm) andalso valid_id(Token),
        {ok, #{node => Node, cookie => Cookie, swarm => Swarm, token => Token}};
parse_query(<<"/v2">>, [{<<"desk">>, Desk}, {<<"mailbox">>, Cap}, {<<"node">>, Node},
                         {<<"swarm">>, Swarm}, {<<"token">>, Token}]) ->
    true = parvi_relay:valid_url(Desk) andalso parvi_swarm_wire:hex(Node, 64) andalso
           valid_id(Cap) andalso valid_id(Swarm) andalso valid_id(Token),
    {ok, #{desk => Desk, mailbox => Cap, node => Node, swarm => Swarm, token => Token}}.

valid_id(Id) when is_binary(Id), byte_size(Id) =:= 32 ->
    re:run(Id, <<"^[0-9A-F]{32}$">>, [{capture, none}]) =:= match;
valid_id(_) -> false.
