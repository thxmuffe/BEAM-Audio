-module(ba_session_privileges_tests).
-include_lib("eunit/include/eunit.hrl").
-define(P,ba_session_privileges).

fixture() ->
    #{<<"members">> => #{a => #{<<"permissions">> => ?P:creator([])},
        b => #{<<"permissions">> => []},c => #{<<"permissions">> => []}}}.
held(Id,P) -> ?P:names(?P:held(Id,P)).

creator_starts_with_grant_on_air_and_end_test() ->
    ?assertEqual([<<"end_session">>,<<"grant">>,<<"on_air">>],held(a,fixture())),
    ?assertEqual([],held(b,fixture())).

privileges_are_independent_test() ->
    P=fixture(),{ok,P1}=?P:change(a,a,take,?P:wire(on_air),P),
    ?assertEqual([<<"end_session">>,<<"grant">>],held(a,P1)),
    {ok,P2}=?P:change(a,b,grant,?P:wire(on_air),P1),
    ?assertEqual([<<"on_air">>],held(b,P2)),
    {ok,P3}=?P:change(a,b,grant,?P:wire(grant),P2),
    ?assertEqual([<<"grant">>,<<"on_air">>],held(b,P3)),
    {ok,P4}=?P:change(b,a,take,?P:wire(grant),P3),
    ?assertEqual([<<"end_session">>],held(a,P4)),
    ?assertEqual({error,grant_required},?P:change(a,c,grant,?P:wire(on_air),P4)).

only_grant_holders_change_privileges_test() ->
    {ok,P}=?P:change(a,b,grant,?P:wire(on_air),fixture()),
    ?assertEqual({error,grant_required},?P:change(b,c,grant,?P:wire(grant),P)),
    ?assertEqual({error,grant_required},?P:change(c,c,grant,?P:wire(on_air),P)),
    ?assertEqual({error,unknown_device},?P:change(a,d,grant,?P:wire(on_air),P)).

no_grant_holder_is_a_valid_continuing_session_test() ->
    {ok,P}=?P:change(a,a,take,?P:wire(grant),fixture()),
    ?assertEqual([],?P:holders(grant,P)),
    ?assertEqual([<<"end_session">>,<<"on_air">>],held(a,P)).

end_session_is_its_own_privilege_test() ->
    {ok,P}=?P:change(a,b,grant,?P:wire(end_session),fixture()),
    ?assert(?P:has(end_session,b,P)),?assertNot(?P:has(grant,b,P)),
    {ok,P1}=?P:change(a,a,take,?P:wire(end_session),P),
    ?assertNot(?P:has(end_session,a,P1)),?assert(?P:has(grant,a,P1)).

microphone_contribution_needs_no_privilege_test() ->
    ?assert(?P:may_publish([],<<"microphone">>)),
    ?assertNot(?P:may_publish([],<<"default-output">>)),
    ?assertNot(?P:may_publish([?P:wire(grant)],<<"default-output">>)),
    ?assert(?P:may_publish([?P:wire(on_air)],<<"default-output">>)).

names_never_accept_retired_spellings_test() ->
    ?assertEqual(<<"owner">>,?P:parse(<<"grant">>)),
    ?assertEqual(<<"stream_publish">>,?P:parse(<<"on_air">>)),
    ?assertEqual(<<"end_session">>,?P:parse(<<"end_session">>)),
    ?assertError(_,?P:parse(<<"owner">>)),?assertError(_,?P:parse(<<"chef">>)).
