-module(ba_buffee_roles_tests).
-include_lib("eunit/include/eunit.hrl").

fixture() ->
    #{<<"members">> => #{a => #{<<"permissions">> => ba_buffee_roles:initial([])},
        b => #{<<"permissions">> => []},c => #{<<"permissions">> => []}}}.

ownership_and_participation_are_independent_test() ->
    P=fixture(),{ok,P1}=ba_buffee_roles:change(a,a,guest,P),
    ?assertEqual([owner,guest],ba_buffee_roles:roles(a,P1)),
    {ok,P2}=ba_buffee_roles:change(a,b,chef,P1),
    ?assertEqual([chef],ba_buffee_roles:roles(b,P2)),
    {ok,P3}=ba_buffee_roles:change(a,b,owner,P2),
    ?assertEqual([owner,chef],ba_buffee_roles:roles(b,P3)),
    {ok,P4}=ba_buffee_roles:change(b,a,remove_owner,P3),
    ?assertEqual([guest],ba_buffee_roles:roles(a,P4)),
    ?assertEqual({error,owner_only},ba_buffee_roles:change(a,c,chef,P4)).

chef_and_manager_placement_do_not_grant_ownership_test() ->
    {ok,P}=ba_buffee_roles:change(a,b,chef,fixture()),
    ?assertEqual({error,owner_only},ba_buffee_roles:change(b,c,owner,P)),
    ?assertEqual({error,owner_only},ba_buffee_roles:change(c,c,chef,P)).

no_owners_is_a_valid_continuing_buffee_test() ->
    {ok,P}=ba_buffee_roles:change(a,a,remove_owner,fixture()),
    ?assertEqual([chef],ba_buffee_roles:roles(a,P)),
    ?assertEqual([guest],ba_buffee_roles:roles(b,P)).

microphone_contribution_is_separate_from_music_publication_test() ->
    ?assert(ba_buffee_roles:may_publish([guest],<<"microphone">>)),
    ?assertNot(ba_buffee_roles:may_publish([guest],<<"default-output">>)),
    ?assertNot(ba_buffee_roles:may_publish([owner,guest],<<"default-output">>)),
    ?assert(ba_buffee_roles:may_publish([chef],<<"default-output">>)).
