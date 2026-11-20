%% Exact signed-control payloads; full nanoseconds use canonical decimal strings.
-module(ba_session_time_protocol).
-export([validate/1,integer/1,encode/1,timeline/2,permission/1,state/1,accept/2]).
validate(#{<<"kind">> := Kind} = P) ->
    case Kind of
        <<"sample.request">> -> exact(P,[<<"kind">>,<<"t1">>]),integer(maps:get(<<"t1">>,P));
        <<"sample.reply">> ->
            exact(P,[<<"kind">>,<<"t1">>,<<"t2">>,<<"t3">>,<<"instance">>,<<"timeline">>,<<"reference_revision">>,<<"uncertainty_ns">>]),
            [integer(maps:get(K,P)) || K <- [<<"t1">>,<<"t2">>,<<"t3">>]],
            true = integer(maps:get(<<"t2">>,P))>0,
            true = integer(maps:get(<<"t3">>,P))>=integer(maps:get(<<"t2">>,P)),
            true = ba_hex:valid(maps:get(<<"instance">>,P),32),
            positive(maps:get(<<"reference_revision">>,P)),
            T = maps:get(<<"timeline">>,P),true = is_binary(T) andalso byte_size(T)=:=72,
            case maps:get(<<"uncertainty_ns">>,P) of null -> ok;B -> true = integer(B)>=0 end;
        <<"offset.get">> -> exact(P,[<<"kind">>]);
        <<"offset.set">> -> policy_shape(P),state(P);
        <<"offset.required">> -> exact(P,[<<"kind">>,<<"revision">>,<<"offset_ms">>]),state(P);
        _ when Kind=:= <<"offset.state">>;Kind=:= <<"offset.changed">> ->
            policy_shape(P),state(P);
        <<"error">> ->
            exact(P,[<<"kind">>,<<"operation">>,<<"reason">>]),
            true = lists:member(maps:get(<<"operation">>,P),[<<"sample.request">>,<<"offset.get">>,<<"offset.set">>,<<"offset.required">>]),
            true = lists:member(maps:get(<<"reason">>,P),[<<"forbidden">>,<<"unavailable">>,<<"conflict">>])
    end,ok.
permission(<<"sample.request">>) -> time_read;
permission(<<"offset.get">>) -> time_read;
permission(<<"offset.set">>) -> offset_write;
permission(<<"offset.required">>) -> time_read;
permission(_) -> none.
state(P) ->
    positive(maps:get(<<"revision">>,P)),D = maps:get(<<"offset_ms">>,P),
    true = is_integer(D) andalso D>=5 andalso D=<30000,
    true = is_boolean(maps:get(<<"automatic">>,P,false)),ok.
accept(New,undefined) -> state(New),New;
accept(#{<<"revision">> := N,<<"offset_ms">> := V} = New,#{<<"revision">> := O,<<"offset_ms">> := Old}=Previous) ->
    state(New),true = N>=O,
    case N=:=O andalso (V=/=Old orelse maps:get(<<"automatic">>,New,false)=/=maps:get(<<"automatic">>,Previous,false)) of
        true -> error(conflicting_revision);false -> New end.
policy_shape(P) ->
    Keys=[<<"kind">>,<<"revision">>,<<"offset_ms">>],
    exact(P,case maps:is_key(<<"automatic">>,P) of true -> [<<"automatic">>|Keys];false -> Keys end).
positive(N) -> true = is_integer(N) andalso N>0 andalso N=<9007199254740991,ok.
integer(B) when is_binary(B),byte_size(B)>0,byte_size(B)=<20 ->
    N = binary_to_integer(B),B = integer_to_binary(N),
    true = N>=-9223372036854775808 andalso N=<9223372036854775807,N.
encode(N) when is_integer(N) -> B = integer_to_binary(N),N = integer(B),B.
timeline(Session,Instance) -> <<"utc/v2/",Session/binary,"/",Instance/binary>>.
exact(P,Keys) -> ba_session_passport:exact(P,Keys).
