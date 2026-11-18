-module(ba_media_session_setup_tests).
-include_lib("eunit/include/eunit.hrl").
%% Connection-setup stages name the step a failed attempt reached.

base(Role) -> #{role => Role,open => false,setup => #{signaling => none,gathering => new,ice => new,dtls => new,
    connection => new,local => #{},remote => #{},stun_urls => 0,turn_urls => 0}}.
with(Changes,#{setup := Setup}=S) -> S#{setup := maps:merge(Setup,Changes)}.

stage_follows_setup_progress_test() ->
    P=base(provider),R=base(receiver),
    ?assertEqual(offer_pending,ba_media_session:stage(P)),
    ?assertEqual(no_offer,ba_media_session:stage(R)),
    ?assertEqual(no_answer,ba_media_session:stage(with(#{signaling => offer_sent},P))),
    Answered=with(#{signaling => answer_received},P),
    ?assertEqual(no_local_candidates,ba_media_session:stage(Answered)),
    Local=with(#{local => #{host => 2}},Answered),
    ?assertEqual(no_remote_candidates,ba_media_session:stage(Local)),
    Both=with(#{remote => #{srflx => 1}},Local),
    ?assertEqual(ice_new,ba_media_session:stage(Both)),
    ?assertEqual(ice_checking,ba_media_session:stage(with(#{ice => checking},Both))),
    ?assertEqual(ice_failed,ba_media_session:stage(with(#{ice => failed},Both))),
    ?assertEqual(dtls,ba_media_session:stage(with(#{ice => connected},Both))),
    ?assertEqual(dtls_failed,ba_media_session:stage(with(#{ice => connected,dtls => failed},Both))),
    ?assertEqual(channel,ba_media_session:stage(with(#{connection => connected},Both))),
    ?assertEqual(open,ba_media_session:stage(Both#{open := true})).

timeout_reason_names_the_stage_test() ->
    ?assertEqual(setup_timeout_ice_checking,ba_media_session:timeout_reason(ice_checking)),
    ?assertEqual(setup_timeout_no_remote_candidates,ba_media_session:timeout_reason(no_remote_candidates)).

candidates_are_counted_by_type_without_addresses_test() ->
    S0=base(receiver),
    S1=ba_media_session:candidate(local,<<"candidate:1 1 UDP 2122 192.168.1.4 5000 typ host">>,S0),
    S2=ba_media_session:candidate(local,<<"candidate:2 1 UDP 1686 203.0.113.9 6000 typ srflx raddr 0.0.0.0 rport 0">>,S1),
    S3=ba_media_session:candidate(remote,<<"candidate:3 1 UDP 2122 abcd-1234.local 7000 typ host">>,S2),
    S4=ba_media_session:candidate(remote,<<>>,S3),
    #{setup := #{local := L,remote := R}}=S4,
    ?assertEqual(#{host => 1,srflx => 1},L),
    ?assertEqual(#{mdns => 1},R),
    ?assertEqual(nomatch,binary:match(iolist_to_binary(io_lib:format("~p",[S4])),<<"192.168">>)).

ice_config_counts_urls_not_credentials_test() ->
    ?assertEqual(#{stun_urls => 1,turn_urls => 0},ba_media_session:ice_config([#{urls => [<<"stun:stun.l.google.com:19302">>]}])),
    ?assertEqual(#{stun_urls => 1,turn_urls => 2},ba_media_session:ice_config([#{urls => <<"stun:a">>},
        #{urls => [<<"turn:b">>,<<"turns:c">>],username => <<"u">>,credential => <<"SECRET">>}])),
    ?assertEqual(#{stun_urls => 0,turn_urls => 0},ba_media_session:ice_config([])).

every_platform_gets_configured_stun_test() ->
    Old=application:get_env(ba_transport,native_ice_servers),
    Stun=application:get_env(ba_core,direct_stun_urls),
    try
        application:unset_env(ba_transport,native_ice_servers),
        application:set_env(ba_core,direct_stun_urls,[<<"stun:stun.example:3478">>]),
        ?assertEqual([#{urls => [<<"stun:stun.example:3478">>]}],ba_media_session:ice_servers()),
        ?assertEqual(#{stun_urls => 1,turn_urls => 0},ba_media_session:ice_config(ba_media_session:ice_servers())),
        application:set_env(ba_transport,native_ice_servers,[#{urls => [<<"turn:relay.example">>]}]),
        ?assertEqual([#{urls => [<<"turn:relay.example">>]}],ba_media_session:ice_servers())
    after
        case Old of undefined -> application:unset_env(ba_transport,native_ice_servers);{ok,V} -> application:set_env(ba_transport,native_ice_servers,V) end,
        case Stun of undefined -> application:unset_env(ba_core,direct_stun_urls);{ok,S} -> application:set_env(ba_core,direct_stun_urls,S) end
    end.

projection_and_console_show_setup_stage_test() ->
    Setup=#{stage => ice_checking,local => #{host => 2},remote => #{host => 1,srflx => 1},stun_urls => 0,turn_urls => 0},
    Subs=#{a => #{state => opening,transport => #{role => receiver,open => false,setup => Setup}},
           b => #{state => opening,transport => #{role => receiver,open => false,setup => Setup}}},
    D=ba_audio_diagnostics:snapshot(#{subscriptions => Subs},#{}),
    ?assertEqual(ok,ba_audio_diagnostics:validate(D)),
    ?assertEqual(2,maps:get(<<"transport.stage.ice_checking">>,D)),
    ?assertEqual(4,maps:get(<<"transport.local_candidates.host">>,D)),
    ?assertEqual(2,maps:get(<<"transport.remote_candidates.srflx">>,D)),
    ?assertEqual(0,maps:get(<<"transport.ice.turn_urls">>,D)),
    View=#{<<"buffee">> => #{},<<"state">> => <<"authorized">>,<<"devices">> => [
        #{<<"id">> => binary:copy(<<"A">>,64),<<"state">> => <<"ok">>,<<"capabilities">> => #{
            <<"audio_diagnostics">> => json:decode(iolist_to_binary(json:encode(D)))}}]},
    Text=unicode:characters_to_binary(ba_cli_monitor:render(View)),
    ?assertNotEqual(nomatch,binary:match(Text,<<"Transport setup: 2 ice_checking  (0/2 open)">>)),
    ?assertNotEqual(nomatch,binary:match(Text,<<"candidates local: 4 host  remote: 2 host 2 srflx">>)),
    ?assertNotEqual(nomatch,binary:match(Text,<<"ICE servers: 0 STUN / 0 TURN">>)).
