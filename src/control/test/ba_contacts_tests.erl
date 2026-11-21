-module(ba_contacts_tests).
-include_lib("eunit/include/eunit.hrl").

contacts_test_() ->
    {setup,
     fun() ->
         application:load(ba_core),
         Saved=[{K,os:getenv(K)} || K <- ["BA_STATE_DIR","BA_IDENTITY_SEED"]],
         Dir=filename:join("/tmp","ba_ephemeral_unit_"++integer_to_list(erlang:unique_integer([positive]))),
         os:putenv("BA_STATE_DIR",Dir),
         os:putenv("BA_IDENTITY_SEED","0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"),
         {ok,Pid}=ba_contacts:start_link(),unlink(Pid),
         {Pid,Saved,Dir}
     end,
     fun({Pid,Saved,Dir}) ->
         gen_server:stop(Pid,shutdown,5000),
         [case V of false -> os:unsetenv(K);_ -> os:putenv(K,V) end || {K,V} <- Saved],
         file:del_dir_r(Dir)
     end,
     [fun starts_empty/0,
      fun names_follow_remembered_sessions/0]}.

starts_empty() ->
    ?assertEqual(#{names => #{}, sessions => #{}}, ba_contacts:list()).

%% Each Session seen is its own entry: its first name is kept, Devices are only
%% added. A Device's last seen name is kept while a remembered Session lists it.
names_follow_remembered_sessions() ->
    A=binary:copy(<<"A">>,64),B=binary:copy(<<"B">>,64),Session=binary:copy(<<"1">>,32),
    ba_contacts:observe(Session,<<"10SWARNING">>,[A,A,B]),
    ba_contacts:observe_name(A,<<"MacBook Air | AABBCCDD">>),
    ba_contacts:observe(Session,<<"Renamed gathering">>,[A,B]),
    ba_contacts:observe_name(A,<<"MacBook Air | NEW00001">>),
    ba_contacts:observe_name(<<"short">>,<<"Invalid">>),
    #{names := Names,sessions := Sessions}=ba_contacts:list(),
    ?assertEqual(#{A => <<"MacBook Air | NEW00001">>},Names),
    ?assertEqual(#{name => <<"10SWARNING">>,devices => #{A => member,B => member}},
                 maps:with([name,devices],maps:get(Session,Sessions))),
    ok=ba_contacts:forget_session(Session),
    ?assertEqual(#{names => #{},sessions => #{}},ba_contacts:list()).
