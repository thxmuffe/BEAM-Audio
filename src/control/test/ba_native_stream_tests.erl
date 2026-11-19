-module(ba_native_stream_tests).
-include_lib("eunit/include/eunit.hrl").
-export([init/1,presentation/1]).

profile_round_trip_test() ->
    D=#{encoding => pcm,sample_format => float32_le,sample_rate => 48000,channel_count => 2,
        clock => <<"clock">>,stream_handler => native_gst_aac},
    O=#{name => <<"Music">>,paused => false,profiles => #{channel => D}},
    Wire=ba_audio_stream_protocol:offer(<<"output">>,binary:copy(<<"A">>,32),O),
    ?assertEqual(<<"gst_aac_rtp_v2">>,maps:get(<<"transport">>,Wire)),
    ?assertEqual(D,ba_audio_stream_protocol:descriptor(Wire)),
    ?assertEqual(ba_stream_handler_native,ba_stream_handler:for_descriptor(D)),
    ?assertException(error,_,ba_audio_stream_protocol:validate(Wire#{<<"transport">> := <<"unknown">>})),
    ?assertException(error,_,ba_audio_stream_protocol:validate(Wire#{<<"format">> := <<"pcm16_le">>})),
    ?assertEqual(ba_stream_handler_pcm,ba_stream_handler:for_descriptor(maps:remove(stream_handler,D))).

owner_loss_stops_native_test() -> fixture(fun(Args,Owner) ->
    {ok,P}=ba_native_media_session:start_link(Args),unlink(P),Ref=monitor(process,P),
    prepared(),exit(Owner,kill),stopped(),down(Ref,P)
end).

session_kill_closes_owned_socket_test() -> fixture(fun(Args,_) ->
    {ok,P}=ba_native_media_session:start_link(Args),unlink(P),Ref=monitor(process,P),
    prepared(),exit(P,kill),
    receive native_closed -> ok after 2000 -> error(socket_survived_owner) end,down(Ref,P)
end).

supervisor_kill_stops_native_test() -> fixture(fun(Args,_) ->
    {ok,Sup}=supervisor:start_link(?MODULE,Args),unlink(Sup),
    [{native,P,_,_}]=supervisor:which_children(Sup),Ref=monitor(process,P),prepared(),
    exit(Sup,kill),stopped(),down(Ref,P)
end).

registry_loss_stops_native_test() -> fixture(fun(Args,_) ->
    Registry=spawn(fun() -> receive quit -> ok end end),true=register(ba_permission_pg,Registry),
    try
        {ok,P}=ba_native_media_session:start_link(Args),unlink(P),Ref=monitor(process,P),prepared(),
        exit(Registry,kill),stopped(),down(Ref,P)
    after exit(Registry,kill) end
end).

revocation_waits_for_native_ack_test() -> fixture(fun(Args,_) ->
    {ok,P}=ba_native_media_session:start_link(Args),unlink(P),Ref=monitor(process,P),prepared(),
    ?assertEqual(ok,gen_server:call(P,{revoke_permissions,[speaker]})),stopped(),down(Ref,P)
end).

init(Args) -> {ok,{#{strategy => one_for_one,intensity => 1,period => 5},
    [#{id => native,start => {ba_native_media_session,start_link,[Args]},restart => temporary}]}}.
prepared() -> receive native_prepared -> ok after 2000 -> error(missing_prepare) end.
stopped() -> receive native_stopped -> ok after 2000 -> error(missing_stop_ack) end.
down(Ref,P) -> receive {'DOWN',Ref,process,P,_} -> ok after 2000 -> error(worker_survived_owner) end.
fixture(F) ->
    Saved=[{K,os:getenv(K)} || K <- ["BA_NATIVE_STREAM_TRIAL","BA_NATIVE_STREAM_PORT"]],
    Old=[{K,application:get_env(ba_core,K)} || K <- [runtime_profile,audio_consent,audio_clock_adapter]],
    application:set_env(ba_core,runtime_profile,legacy_apps),application:set_env(ba_core,audio_consent,#{speaker => true}),
    application:set_env(ba_core,audio_clock_adapter,?MODULE),
    os:putenv("BA_NATIVE_STREAM_TRIAL","1"),
    {ok,L}=gen_tcp:listen(0,[binary,{packet,4},{active,false},{ip,{127,0,0,1}}]),
    {ok,{_,Port}}=inet:sockname(L),os:putenv("BA_NATIVE_STREAM_PORT",integer_to_list(Port)),
    Parent=self(),{Server,SR}=spawn_monitor(fun() ->
        {ok,S}=gen_tcp:accept(L,2000),
        try
            {ok,B}=gen_tcp:recv(S,0,2000),#{<<"generation">> := G}=json:decode(B),
            ok=gen_tcp:send(S,json:encode(#{event => <<"hello">>,version => 2,generation => G,
                profile => <<"gst_aac_rtp_v2">>,owner_loss_stop => true,stop_ack => true,schedule => true})),
            expect_prepare(S,G),Parent ! native_prepared,serve(S,G,Parent)
        after gen_tcp:close(S) end
    end),
    Owner=spawn(fun() -> receive quit -> ok end end),
    Args=#{owner => Owner,role => receiver,descriptor => #{sample_rate => 48000,channel_count => 2,clock => <<"clock">>},
        context => #{deadline => erlang:monotonic_time(millisecond)+10000}},
    try F(Args,Owner),receive {'DOWN',SR,process,Server,normal} -> ok after 2000 -> error(server_failed) end
    after
        exit(Owner,kill),exit(Server,kill),gen_tcp:close(L),
        [case V of false -> os:unsetenv(K);_ -> os:putenv(K,V) end || {K,V} <- Saved],
        [case V of undefined -> application:unset_env(ba_core,K);{ok,X} -> application:set_env(ba_core,K,X) end || {K,V} <- Old]
    end.
serve(S,G,Parent) ->
    case gen_tcp:recv(S,0,3000) of
        {ok,B} -> case json:decode(B) of
            #{<<"op">> := <<"stop">>,<<"request_id">> := Id} ->
                ok=gen_tcp:send(S,json:encode(#{event => <<"stopped">>,request_id => Id,generation => G})),Parent ! native_stopped;
            _ -> serve(S,G,Parent)
        end;
        {error,closed} -> Parent ! native_closed
    end.

presentation(Times) -> {ok,#{clock => <<"clock">>,offset_ms => 800,offset_revision => 1,
    times => [2000000000000000000+T || T <- Times]}}.
expect_prepare(S,G) ->
    {ok,B}=gen_tcp:recv(S,0,2000),C=json:decode(B),
    case C of
        #{<<"op">> := <<"clock">>,<<"sent_ns">> := Sent} ->
            ok=gen_tcp:send(S,json:encode(#{event => <<"clock">>,generation => G,sent_ns => Sent,
                internal_ns => <<"1000000000">>,session_ns => null})),expect_prepare(S,G);
        #{<<"op">> := <<"clock_map">>,<<"timeline">> := <<"clock">>,<<"session_ns">> := Time} ->
            ?assert(is_binary(Time)),expect_prepare(S,G);
        #{<<"op">> := <<"prepare">>,<<"buffer_ms">> := 800} -> ok
    end.

clock_mapping_rejects_a_changed_timeline_test() ->
    Old=application:get_env(ba_core,audio_clock_adapter),application:set_env(ba_core,audio_clock_adapter,?MODULE),
    try
        E=#{<<"internal_ns">> => <<"100">>,<<"session_ns">> => null},
        ?assertMatch({ok,#{session_ns := _},#{offset_ms := 800}},ba_audio_native_clock:plan(E,0,100,#{clock => <<"clock">>},#{})),
        {ok,_,Meta}=ba_audio_native_clock:plan(E,0,100,#{clock => <<"clock">>},#{}),
        ?assertMatch({ok,#{correction_ppm := 500,revision := 2},_},
            ba_audio_native_clock:plan(E#{<<"session_ns">> := <<"1000">>},0,100,#{clock => <<"clock">>},Meta)),
        ?assertEqual({error,presentation_changed},
            ba_audio_native_clock:plan(E,0,100,#{clock => <<"clock">>},Meta#{offset_ms := 900})),
        ?assertEqual({error,clock_mapping_unavailable},ba_audio_native_clock:plan(E,0,100,#{clock => <<"old-clock">>},#{}))
    after case Old of undefined -> application:unset_env(ba_core,audio_clock_adapter);{ok,V} -> application:set_env(ba_core,audio_clock_adapter,V) end end.
