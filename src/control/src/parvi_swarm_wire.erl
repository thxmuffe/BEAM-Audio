%% Explicit JSON schema. Never decode Erlang external terms or allocate atoms.
-module(parvi_swarm_wire).
-export([encode/2, decode/1, hex/2, valid_signal/1]).
encode(Id, {rtc, Id, Sender, Signal}) ->
    #{type => <<"rtc">>, swarm => Id, sender => Sender, signal => Signal};
encode(Id, {join_request, Request, Token, Member}) ->
    #{type => <<"join">>, swarm => Id, request => Request, token => Token, member => member(Member)};
encode(Id, {join_reply, Request, {ok, Shared}}) ->
    #{type => <<"joined">>, swarm => Id, request => Request, state => shared(Shared)};
encode(Id, {join_reply, Request, {error, Error}}) ->
    #{type => <<"rejected">>, swarm => Id, request => Request, error => Error};
encode(Id, {membership, Sender, Shared}) ->
    #{type => <<"membership">>, swarm => Id, sender => Sender, state => shared(Shared)};
encode(Id, {departure, Id, Sender, Removed, Revoked}) ->
    #{type => <<"departure">>, swarm => Id, sender => Sender, removed => Removed, revoked => Revoked};
encode(Id, {chat, Id, Sender, M}) ->
    #{type => <<"chat">>, swarm => Id, sender => Sender,
      message => #{id => maps:get(id, M), sender => maps:get(sender, M), text => maps:get(text, M), time => maps:get(sent_at_ms, M)}}.
member(#{id := Id, node := Node, via := Via, mailbox := Cap}) ->
    #{id => Id, node => Node, via => case Via of none -> null; _ -> Via end, mailbox => Cap}.
shared(#{id := Id, name := Name, members := Members, removed := Removed, revoked := Revoked}) ->
    #{id => Id, name => Name, members => [member(M) || M <- maps:values(Members)], removed => Removed, revoked => Revoked}.
decode(#{<<"swarm">> := Id} = M) ->
    try true = hex(Id, 32), {ok, Id, event(M, Id)} catch _:_ -> {error, invalid_message} end;
decode(_) -> {error, invalid_message}.
event(#{<<"type">> := <<"rtc">>, <<"sender">> := Sender, <<"signal">> := Signal}, Id) ->
    true = hex(Sender, 32) andalso valid_signal(Signal), {rtc, Id, Sender, Signal};
event(#{<<"type">> := <<"join">>, <<"request">> := R, <<"token">> := T, <<"member">> := M}, Id) ->
    true = hex(R, 32) andalso hex(T, 32), {join_request, Id, R, T, read_member(M)};
event(#{<<"type">> := <<"joined">>, <<"request">> := R, <<"state">> := S}, Id) ->
    true = hex(R, 32), {join_reply, Id, R, {ok, read_shared(S, Id)}};
event(#{<<"type">> := <<"rejected">>, <<"request">> := R, <<"error">> := Error}, Id) ->
    true = hex(R, 32) andalso text(Error, 256), {join_reply, Id, R, {error, Error}};
event(#{<<"type">> := <<"membership">>, <<"sender">> := Sender, <<"state">> := S}, Id) ->
    true = hex(Sender, 32), {membership, Sender, read_shared(S, Id)};
event(#{<<"type">> := <<"departure">>, <<"sender">> := Sender, <<"removed">> := Removed, <<"revoked">> := Revoked}, Id) ->
    true = hex(Sender, 32) andalso ids(Removed) andalso ids(Revoked), {departure, Id, Sender, Removed, Revoked};
event(#{<<"type">> := <<"chat">>, <<"sender">> := Sender,
        <<"message">> := #{<<"id">> := Mid, <<"sender">> := Node, <<"text">> := Text, <<"time">> := Time}}, Id) ->
    true = hex(Sender, 32) andalso hex(Mid, 32) andalso hex(Node, 64) andalso text(Text, 4096),
    true = is_integer(Time) andalso Time >= 0 andalso Time < 9007199254740992,
    {chat, Id, Sender, #{version => 1, id => Mid, sender => Node, text => Text, sent_at_ms => Time}}.
read_member(#{<<"id">> := Id, <<"node">> := Node, <<"via">> := Via, <<"mailbox">> := Cap}) ->
    true = hex(Id, 32) andalso hex(Node, 64) andalso hex(Cap, 32) andalso (Via =:= null orelse hex(Via, 32)),
    #{id => Id, node => Node, via => case Via of null -> none; _ -> Via end, mailbox => Cap}.
read_shared(#{<<"id">> := Id, <<"name">> := Name, <<"members">> := Rows,
              <<"removed">> := Removed, <<"revoked">> := Revoked}, Id) ->
    true = text(Name, 80) andalso is_list(Rows) andalso length(Rows) > 0 andalso length(Rows) =< 64,
    true = ids(Removed) andalso ids(Revoked),
    Members = [read_member(M) || M <- Rows],
    ByNode = maps:from_list([{maps:get(node, M), M} || M <- Members]),
    true = map_size(ByNode) =:= length(Rows),
    #{id => Id, name => Name, members => ByNode, removed => Removed, revoked => Revoked}.
ids(L) when is_list(L), length(L) =< 1024 -> lists:all(fun(I) -> hex(I, 32) end, L);
ids(_) -> false.
valid_signal(#{<<"session">> := Session, <<"kind">> := Kind} = S) ->
    hex(Session, 32) andalso case Kind of
        <<"offer">> -> text(maps:get(<<"sdp">>, S, <<>>), 32768);
        <<"answer">> -> text(maps:get(<<"sdp">>, S, <<>>), 32768);
        <<"candidate">> -> text(maps:get(<<"candidate">>, S, <<>>), 4096) andalso
            text(maps:get(<<"mid">>, S, <<>>), 256) andalso
            is_integer(maps:get(<<"index">>, S, null)) andalso
            maps:get(<<"index">>, S) >= 0 andalso maps:get(<<"index">>, S) < 256;
        _ -> false
    end;
valid_signal(_) -> false.
hex(B, N) when is_binary(B), byte_size(B) =:= N -> re:run(B, <<"^[0-9A-F]+$">>, [{capture, none}]) =:= match;
hex(_, _) -> false.
text(B, N) when is_binary(B), byte_size(B) > 0, byte_size(B) =< N -> unicode:characters_to_binary(B, utf8, utf8) =:= B;
text(_, _) -> false.
