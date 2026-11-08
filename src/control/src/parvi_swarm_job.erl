%% Fixed step-4 data shapes. No modules/functions/resource handles on the wire.
-module(parvi_swarm_job).
-export([validate_offer/1,validate_report/1,report/3,terminal/1,hex/2]).
validate_offer(P) ->
    exact(P,[<<"contract">>,<<"contract_revision">>,<<"capability">>,<<"duration_ms">>,<<"lease_ms">>]),
    true = hex(maps:get(<<"contract">>,P),32),
    R = maps:get(<<"contract_revision">>,P), true = is_integer(R) andalso R > 0 andalso R =< 9007199254740991,
    <<"test">> = maps:get(<<"capability">>,P),
    [begin N = maps:get(K,P),true = is_integer(N) andalso N >= 20 andalso N =< 10000 end ||
        K <- [<<"duration_ms">>,<<"lease_ms">>]], ok.
validate_report(P) ->
    exact(P,[<<"attempt">>,<<"state">>,<<"reason">>]),
    #{<<"attempt">> := Attempt,<<"state">> := State,<<"reason">> := Reason} = P,
    true = Attempt =:= null orelse hex(Attempt,32),
    true = lists:member(State,[<<"accepted">>,<<"completed">>,<<"failed">>,
                               <<"cancelled">>,<<"expired">>,<<"rejected">>]),
    true = lists:member(Reason,[<<"none">>,<<"contract_mismatch">>,<<"consent_required">>,
        <<"capacity_exceeded">>,<<"job_limit">>,<<"conflicting_offer">>,<<"handler_unavailable">>,
        <<"worker_failed">>,<<"lease_expired">>,<<"cancelled">>,<<"consent_revoked">>,
        <<"session_lost">>,<<"contract_revoked">>]),
    case State of
        <<"accepted">> -> true = hex(Attempt,32), <<"none">> = Reason;
        <<"completed">> -> true = hex(Attempt,32), <<"none">> = Reason;
        <<"rejected">> -> null = Attempt;
        _ -> ok
    end, ok.
report(Attempt,State,Reason) ->
    P = #{<<"attempt">> => Attempt,<<"state">> => State,<<"reason">> => Reason},
    ok = validate_report(P), P.
terminal(<<"accepted">>) -> false;
terminal(<<"offered">>) -> false;
terminal(<<"cancel_pending">>) -> false;
terminal(<<"unconfirmed">>) -> false;
terminal(_) -> true.
exact(M,Keys) -> true = is_map(M),true = lists:sort(maps:keys(M)) =:= lists:sort(Keys).
hex(B,N) when is_binary(B),byte_size(B) =:= N ->
    re:run(B,<<"^[0-9A-F]+$">>,[{capture,none}]) =:= match;
hex(_,_) -> false.
