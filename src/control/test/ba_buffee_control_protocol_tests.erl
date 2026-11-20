-module(ba_buffee_control_protocol_tests).
-include_lib("eunit/include/eunit.hrl").

fixture() ->
    KA = {PA,_} = crypto:generate_key(eddsa,ed25519),
    KB = {PB,_} = crypto:generate_key(eddsa,ed25519),
    A = binary:encode_hex(PA), B = binary:encode_hex(PB),
    {A,B,KA,KB,
     ba_buffee_control_protocol:new(KA,policy(A,#{B => [status_read]}),0),
     ba_buffee_control_protocol:new(KB,policy(B,#{A => [status_read]}),0)}.
buffee() -> binary:copy(<<"A">>,32).
invitation() -> ba_buffee_passport:invitation_key(binary:copy(<<"5">>,32)).
%% Each Device signs its own join certificate with the link's invitation key.
policy(Self,Members) ->
    {Invitation,Key} = invitation(),
    #{buffee => buffee(),authority => Self,manager => Self,revision => 1,invitation => Invitation,
      join => ba_buffee_passport:join(buffee(),Self,Key),members => Members,defaults => [],removed => []}.

otp_diagnostics_redact_keys_test() ->
    {_,_,_,_,P,_} = fixture(),
    Secret = <<"test-only-private-key-must-not-appear">>,
    Status = #{state => #{protocol => P#{private := Secret},private => Secret},
               message => Secret,reason => Secret,log => [Secret]},
    [?assertEqual(nomatch,binary:match(term_to_binary(Formatted),Secret)) || Formatted <-
        [ba_buffee_control:format_status(Status),ba_relay:format_status(Status)]].

%% One hello and its ready: both sides now hold the relationship.
connected() ->
    {A,B,KA,KB,SA,SB} = fixture(),
    {ok,Hello,A1} = p(connect,[B,0,SA]),
    {ok,[Ready],[authorized],B1} = p(receive_packet,[A,Hello,1,SB]),
    {ok,[],[authorized],A2} = p(receive_packet,[B,Ready,2,A1]),
    {A,B,KA,KB,A2,B1}.

%% GStreamer emits an empty candidate when gathering finishes. It must travel
%% through signed signalling without closing an otherwise valid media attempt.
end_of_candidates_roundtrip_test() ->
    {A,B,_,_,SA,SB} = connected(),
    Id=binary:copy(<<"C">>,32),
    P=#{<<"kind">> => <<"signal.candidate">>,<<"source">> => <<"music">>,
        <<"incarnation">> => binary:copy(<<"D">>,32),<<"attempt">> => binary:copy(<<"E">>,32),
        <<"candidate">> => <<>>,<<"mid">> => <<"audio0">>,<<"line">> => 0},
    {ok,Packet,_}=p(audio_message,[B,Id,P,5,SA]),
    ?assertMatch({ok,[],[{audio,Id,P,#{peer := A}}],_},p(receive_packet,[A,Packet,6,SB])),
    [?assertException(error,_,ba_audio_stream_protocol:validate(P#{<<"candidate">> := Bad}))
        || Bad <- [null,42,binary:copy(<<"x">>,1025)]].

status_roundtrip_and_replay_test() ->
    {A,B,_,_,SA,SB} = connected(),
    {ok,Request,A1} = p(request_status,[B,5,SA]),
    {ok,[Response],[],B1} = p(receive_packet,[A,Request,6,SB]),
    {ok,[],[{reply,<<"status.reply">>,#{<<"protocol">> := 1}}],A2} =
        p(receive_packet,[B,Response,7,A1]),
    ?assertMatch({error,_,B1},p(receive_packet,[A,Request,8,B1])),
    ?assertMatch({error,_,A2},p(receive_packet,[B,Response,8,A2])).

capability_permissions_and_reply_test() ->
    {A,B,_,KB,SA,SB} = connected(),
    {ok,Denied,A0} = p(request_capabilities,[B,5,SA]),
    {ok,[Error],[],_} = p(receive_packet,[A,Denied,6,SB]),
    ?assertMatch({ok,[],[{reply,<<"capabilities.error">>,#{<<"reason">> := <<"forbidden">>}}],_},
        p(receive_packet,[B,Error,7,A0])),
    Policy = maps:get(policy,SB),
    Granted = SB#{policy := Policy#{members := #{A => [capabilities_read,status_read]}}},
    {ok,Query,A1} = p(request_capabilities,[B,5,SA]),
    {ok,[],[{capabilities_read,Request}],B1} = p(receive_packet,[A,Query,6,Granted]),
    Caps = #{<<"instance">> => binary:copy(<<"A">>,32),<<"revision">> => 0},
    {ok,Reply,B2} = p(reply_capabilities,[A,Request,Caps,7,B1]),
    WrongKind = resign(Reply,KB,fun(M) -> M#{<<"op">> := <<"status.reply">>,
        <<"payload">> := #{<<"protocol">> => 1,<<"session">> => <<"authorized">>}} end),
    ?assertMatch({error,_,A1},p(receive_packet,[B,WrongKind,8,A1])),
    BadCaps = resign(Reply,KB,fun(M) -> M#{<<"payload">> := Caps#{<<"module">> => <<"os">>}} end),
    ?assertMatch({error,_,A1},p(receive_packet,[B,BadCaps,8,A1])),
    {ok,[],[{reply,<<"capabilities.reply">>,Caps}],A2} = p(receive_packet,[B,Reply,8,A1]),
    ?assertMatch({error,_,A2},p(receive_packet,[B,Reply,9,A2])),
    ?assertMatch({error,_,B2},p(reply_capabilities,[A,Request,Caps,9,B2])),
    {ok,Unavailable,_} = p(reply_capabilities,[A,Request,unavailable,7,B1]),
    ?assertMatch({ok,[],[{reply,<<"capabilities.error">>,#{<<"reason">> := <<"unavailable">>}}],_},
        p(receive_packet,[B,Unavailable,8,A1])).

sender_signature_and_join_certificate_are_bound_test() ->
    {A,B,KA,_,SA,SB} = connected(),
    {ok,FromA,_} = p(request_capabilities,[B,5,SA]),
    {ok,FromB,_} = p(request_capabilities,[A,5,SB]),
    %% B's request re-signed with A's key is not B's.
    ?assertMatch({error,_,SA},p(receive_packet,[B,resign(FromB,KA,fun(M) -> M end),6,SA])),
    %% A Device's join certificate cannot be reused by another Device.
    Borrowed = resign(FromA,KA,fun(M) -> M#{<<"join">> := maps:get(<<"join">>,body(FromB))} end),
    ?assertMatch({error,_,SB},p(receive_packet,[A,Borrowed,6,SB])).

forgery_recipient_scope_and_policy_test() ->
    {A,B,KA,KB,SA,SB} = connected(),
    {ok,Request,_} = p(request_status,[B,5,SA]),
    BadSigner = resign(Request,KB,fun(M) -> M end),
    ?assertMatch({error,_,SB},p(receive_packet,[A,BadSigner,6,SB])),
    ?assertMatch({error,_,SB},p(receive_packet,[B,Request,6,SB])),
    [?assertMatch({error,_,SB},p(receive_packet,[A,resign(Request,KA,F),6,SB])) || F <-
        [fun(M) -> M#{<<"to">> := A} end,
         fun(M) -> M#{<<"buffee">> := binary:copy(<<"B">>,32)} end,
         fun(M) -> M#{<<"join">> := binary:copy(<<"0">>,128)} end,
         fun(M) -> M#{<<"v">> := 999} end,
         fun(M) -> M#{<<"extra">> => true} end,
         fun(M) -> M#{<<"payload">> := #{<<"module">> => <<"os">>}} end]],
    %% A forged high sequence cannot advance replay state.
    ForgedHigh = resign(Request,KB,fun(M) -> M#{<<"seq">> := 500} end),
    ?assertMatch({error,_,SB},p(receive_packet,[A,ForgedHigh,6,SB])),
    ?assertMatch({ok,[_],[],_},p(receive_packet,[A,Request,7,SB])).

forbidden_operation_test() ->
    {A,B,KA,_,SA,SB} = connected(),
    {ok,Request,_} = p(request_status,[B,5,SA]),
    [?assertEqual({error,forbidden_operation,SB},p(receive_packet,
        [A,resign(Request,KA,fun(M) -> M#{<<"op">> := Op} end),6,SB])) ||
        Op <- [<<"worker.start">>,<<"rpc">>,<<"os.cmd">>,<<"broadcast_start">>]].

permission_and_correlation_test() ->
    {A,B,_,KB,SA,SB} = connected(),
    {ok,Request,A1} = p(request_status,[B,5,SA]),
    Policy = maps:get(policy,SB),
    Denied = SB#{policy := Policy#{members := #{A => []}}},
    {ok,[Error],[],_} = p(receive_packet,[A,Request,6,Denied]),
    ?assertMatch({ok,[],[{reply,<<"status.error">>,_}],_},p(receive_packet,[B,Error,7,A1])),
    {ok,[Response],[],_} = p(receive_packet,[A,Request,6,SB]),
    ?assertMatch({error,_,SA},p(receive_packet,[B,Response,7,SA])),
    WrongId = resign(Response,KB,fun(M) -> M#{<<"request">> := binary:copy(<<"0">>,32)} end),
    ?assertMatch({error,_,A1},p(receive_packet,[B,WrongId,7,A1])),
    ?assertMatch({error,_,A1},p(request_status,[B,8,A1])),
    ?assertMatch({error,_,A1},p(receive_packet,[B,Response,5005,A1])).



malformed_and_size_test() ->
    {A,B,KA,_,SA,SB} = connected(),
    {ok,Request,_} = p(request_status,[B,5,SA]),
    [?assertMatch({error,_,SB},p(receive_packet,[A,Wire,6,SB])) ||
        Wire <- [binary:copy(<<"x">>,32769),<<"garbage">>,<<"[]">>,<<"{}">>,<<255>>,42,
                 <<"{\"body\":\"a\",\"body\":\"b\",\"signature\":\"c\"}">>]],
    Body = body(Request),
    Data = iolist_to_binary(json:encode(Body)),
    <<"{",Rest/binary>> = Data,
    Duplicate = <<"{\"v\":1,",Rest/binary>>,
    ?assertMatch({error,_,SB},p(receive_packet,[A,raw_seal(Duplicate,element(2,KA)),6,SB])),
    BadArray = resign(Request,KA,fun(M) -> M#{<<"payload">> := []} end),
    ?assertMatch({error,_,SB},p(receive_packet,[A,BadArray,6,SB])),
    ?assertMatch({error,_,SB},p(receive_packet,[A,<<Request/binary,"x">>,6,SB])).

membership_and_limits_test() ->
    {A,B,KA,_,SA,SB} = fixture(),
    {ok,Hello,_} = p(connect,[B,0,SA]),
    Policy = maps:get(policy,SB),
    Removed = SB#{policy := Policy#{removed := [A]}},
    ?assertMatch({error,_,Removed},p(receive_packet,[A,Hello,6,Removed])),
    ?assertMatch({error,_,_},p(connect,[B,6,SA#{policy := (maps:get(policy,SA))#{removed := [B]}}])),
    ?assertException(error,_,p(new,[KA,(maps:get(policy,SA))#{join := maps:get(join,maps:get(policy,SB))},0])),
    ?assertMatch({error,_,SA},p(connect,[binary:copy(<<"0">>,63),6,SA])),
    TooMany = maps:from_list([{binary:encode_hex(crypto:strong_rand_bytes(32)),[]} || _ <- lists:seq(1,33)]),
    ?assertException(error,_,p(new,[KA,(maps:get(policy,SA))#{members := TooMany},0])).

%% No membership list: any Device with a valid join certificate may ask, with
%% default rights unless the signed statement gives it more.
any_joined_device_may_ask_with_default_rights_test() ->
    {A,B,_,_,SA,SB} = fixture(),
    {C,_} = KC = crypto:generate_key(eddsa,ed25519),Cid = binary:encode_hex(C),
    SC = p(new,[KC,policy(Cid,#{}),0]),
    {ok,Status,_} = p(request_status,[B,5,SC]),
    ?assertMatch({ok,[_],[authorized],_},p(receive_packet,[Cid,Status,6,SB#{policy := (maps:get(policy,SB))#{defaults := [status_read]}}])),
    {ok,Chat,_} = p(chat_message,[A,binary:copy(<<"C">>,32),<<"hi">>,5,SC]),
    ?assertMatch({ok,[],[authorized,{chat,_,<<"hi">>,_}],_},p(receive_packet,[Cid,Chat,6,SA])),
    %% A certificate from another Session's invitation key does not count.
    {Stranger,Key} = ba_buffee_passport:invitation_key(binary:copy(<<"6">>,32)),
    Outsider = (policy(Cid,#{}))#{invitation := Stranger,join := ba_buffee_passport:join(buffee(),Cid,Key)},
    {ok,Forged,_} = p(request_status,[B,5,p(new,[KC,Outsider,0])]),
    ?assertMatch({error,_,SB},p(receive_packet,[Cid,Forged,6,SB])).

p(F,Args) -> apply(ba_buffee_control_protocol,F,Args).
body(Wire) -> json:decode(base64:decode(maps:get(<<"body">>,json:decode(Wire)))).
resign(Packet,{_,Private},Fun) -> p(seal,[Fun(body(Packet)),Private]).
raw_seal(Data,Private) ->
    Sig = crypto:sign(eddsa,none,[<<"beamaudio-buffee-control/v1:">>,Data],[Private,ed25519]),
    iolist_to_binary(json:encode(#{<<"body">> => base64:encode(Data),<<"signature">> => binary:encode_hex(Sig)})).

membership_deadline_is_synchronous_test() ->
    {A,B,_,_,SA,SB} = connected(),
    Expired = SA#{membership_deadline => 5},
    ?assertMatch({error,_,_},p(request_status,[B,5,Expired])),
    {ok,Packet,_} = p(request_status,[A,5,SB]),
    ?assertMatch({error,_,_},p(receive_packet,[B,Packet,5,Expired])),
    {_,Peer,_,_,Fresh,_} = fixture(),
    ?assertMatch({error,_,_},p(connect,[Peer,5,Fresh#{membership_deadline => 5}])).

catalogue_change_uses_authenticated_audio_channel_test() ->
    {A,B,_,_,SA,SB} = connected(),
    Id=binary:copy(<<"C">>,32),Payload=#{<<"kind">> => <<"catalog.changed">>},
    {ok,Packet,_}=p(audio_message,[B,Id,Payload,5,SA]),
    {ok,[],[{audio,Id,Payload,#{peer := A}}],Received}=p(receive_packet,[A,Packet,6,SB]),
    ?assertMatch({error,_,_},p(receive_packet,[A,Packet,7,Received])).

stream_control_requires_grants_and_exact_schema_test() ->
    {A,B,_,_,SA,SB} = connected(),
    Id = binary:copy(<<"A">>,32),P = #{<<"kind">> => <<"catalog.read">>},
    {ok,Packet,_} = p(audio_message,[B,Id,P,5,SA]),
    ?assertMatch({error,_,SB},p(receive_packet,[A,Packet,6,SB])),
    Policy = maps:get(policy,SB),
    Granted = SB#{policy := Policy#{members := #{A => [stream_read,stream_subscribe]}}},
    ?assertMatch({ok,[],[{audio,Id,P,#{peer := A}}],_},p(receive_packet,[A,Packet,6,Granted])),
    Base = #{<<"source">> => <<"music">>,<<"incarnation">> => Id,<<"attempt">> => Id},
    ?assertMatch({error,_,_},p(audio_message,[B,Id,Base#{<<"kind">> => <<"signal.offer">>,<<"sdp">> => <<"unsigned generic SDP">>},5,SA])),
    ?assertMatch({error,_,_},p(audio_message,[B,Id,P#{<<"pcm">> => <<"audio is not control">>},5,SA])).


time_permission_is_not_implied_by_status_or_membership_test() ->
    {A,B,_,_,SA,SB} = connected(),Id = binary:copy(<<"A">>,32),
    P = #{<<"kind">> => <<"offset.set">>,<<"revision">> => 1,<<"offset_ms">> => 250},
    {ok,Packet,_} = p(time_message,[B,Id,P,5,SA]),
    ?assertMatch({ok,[_],[],_},p(receive_packet,[A,Packet,6,SB])),
    Policy = maps:get(policy,SB),
    GuestWithOldFlag = SB#{policy := Policy#{members := #{A => [offset_write]}}},
    ?assertMatch({ok,[_],[],_},p(receive_packet,[A,Packet,6,GuestWithOldFlag])),
    Owner = SB#{policy := Policy#{members := #{A => [owner]}}},
    ?assertMatch({ok,[],[{time,Id,P,_}],_},p(receive_packet,[A,Packet,6,Owner])),
    Granted = SB#{policy := Policy#{members := #{A => [stream_publish]}}},
    ?assertMatch({ok,[],[{time,Id,P,_}],_},p(receive_packet,[A,Packet,6,Granted])).

ordinary_time_reader_can_request_more_time_but_cannot_enable_automatic_test() ->
    {A,B,_,_,SA,SB} = connected(),Id=binary:copy(<<"E">>,32),
    Policy=maps:get(policy,SB),Reader=SB#{policy := Policy#{members := #{A => [time_read]}}},
    Required=#{<<"kind">> => <<"offset.required">>,<<"revision">> => 2,<<"offset_ms">> => 450},
    {ok,Packet,_}=p(time_message,[B,Id,Required,5,SA]),
    ?assertMatch({ok,[],[{time,Id,Required,_}],_},p(receive_packet,[A,Packet,6,Reader])),
    Auto=#{<<"kind">> => <<"offset.set">>,<<"revision">> => 2,<<"offset_ms">> => 300,<<"automatic">> => true},
    {ok,Change,_}=p(time_message,[B,Id,Auto,5,SA]),
    ?assertMatch({ok,[_],[],_},p(receive_packet,[A,Change,6,Reader])).





chat_is_authenticated_bounded_and_replay_protected_test() ->
    {A,B,_,_,SA,SB} = connected(),Id=binary:copy(<<"D">>,32),
    {ok,Packet,A1}=p(chat_message,[B,Id,<<"hello">>,5,SA]),
    {ok,[],[{chat,Id,<<"hello">>,#{peer := A}}],B1}=p(receive_packet,[A,Packet,6,SB]),
    ?assertMatch({error,_,B1},p(receive_packet,[A,Packet,7,B1])),
    ?assertMatch({error,_,A1},p(chat_message,[B,Id,binary:copy(<<"x">>,4097),8,A1])),
    ?assertMatch({error,_,_},p(chat_message,[A,Id,<<"later">>,6,SB#{membership_deadline => 5}])).

audio_capability_shape_is_bounded_and_authenticated_test() ->
    {A,B,_,_,SA,SB} = connected(),Policy=maps:get(policy,SB),
    Granted=SB#{policy := Policy#{members := #{A => [capabilities_read,status_read]}}},
    {ok,Query,A1}=p(request_capabilities,[B,5,SA]),
    {ok,[],[{capabilities_read,Id}],B1}=p(receive_packet,[A,Query,6,Granted]),
    Entry=#{<<"consent">> => true,<<"available">> => false,<<"state">> => <<"waiting_for_clock">>},
    Caps=#{<<"instance">> => binary:copy(<<"A">>,32),<<"revision">> => 0,
        <<"audio">> => #{<<"speaker">> => Entry,<<"microphone">> => Entry,<<"broadcast">> => Entry}},
    {ok,Reply,_}=p(reply_capabilities,[A,Id,Caps,7,B1]),
    ?assertMatch({ok,[],[{reply,<<"capabilities.reply">>,Caps}],_},p(receive_packet,[B,Reply,8,A1])),
    Bad=Caps#{<<"audio">> := (maps:get(<<"audio">>,Caps))#{<<"execute">> => Entry}},
    ?assertMatch({error,_,B1},p(reply_capabilities,[A,Id,Bad,7,B1])).

meter_request_and_reply_are_opt_in_and_bounded_test() ->
    {A,B,_,_,SA,SB} = connected(),Policy=maps:get(policy,SB),
    Granted=SB#{policy := Policy#{members := #{A => [capabilities_read,status_read]}}},
    {ok,Query,A1}=p(request_capabilities,[B,true,5,SA]),
    {ok,[],[{capabilities_read,Id,true}],B1}=p(receive_packet,[A,Query,6,Granted]),
    E=#{<<"consent">> => true,<<"available">> => true,<<"state">> => <<"running">>,
        <<"peak_db">> => -3.0,<<"rms_db">> => -6.0,<<"meter_age_ms">> => 2,<<"meter_stage">> => <<"capture">>,<<"frames">> => 480},
    Caps=#{<<"audio_diagnostics">> => #{<<"mixer.failure.missed_packet_target">> => 4,<<"clock.state">> => <<"synchronized">>},<<"device_name">> => <<"Paavo’s iPhone (2)"/utf8>>,<<"instance">> => binary:copy(<<"A">>,32),<<"revision">> => 1,
        <<"audio">> => #{<<"speaker">> => E,<<"microphone">> => E,<<"broadcast">> => E}},
    {ok,Reply,_}=p(reply_capabilities,[A,Id,Caps,7,B1]),
    ?assertMatch({ok,[],[{reply,<<"capabilities.reply">>,Caps}],_},p(receive_packet,[B,Reply,8,A1])),
    ?assertMatch({error,_,B1},p(reply_capabilities,[A,Id,Caps#{<<"device_name">> := binary:copy(<<"x">>,257)},7,B1])),
    ?assertMatch({error,_,B1},p(reply_capabilities,[A,Id,Caps#{<<"audio_diagnostics">> := #{<<"pcm">> => <<"secret">>}},7,B1])),
    Bad=Caps#{<<"audio">> := (maps:get(<<"audio">>,Caps))#{<<"broadcast">> := E#{<<"peak_db">> := 999}}},
    ?assertMatch({error,_,B1},p(reply_capabilities,[A,Id,Bad,7,B1])).

remote_diagnostics_control_is_permission_gated_and_replay_safe_test() ->
    {A,B,KA,_,SA,SB} = connected(),
    Options=#{<<"meters">> => false,<<"analysis">> => true},
    {ok,Query,A1}=p(request_capabilities,[B,Options,5,SA]),
    {ok,[Denied],[],_}=p(receive_packet,[A,Query,6,SB]),
    ?assertMatch({ok,[],[{reply,<<"capabilities.error">>,#{<<"reason">> := <<"forbidden">>}}],_},
        p(receive_packet,[B,Denied,7,A1])),
    Policy=maps:get(policy,SB),Granted=SB#{policy := Policy#{members := #{A => [capabilities_read]}}},
    ?assertMatch({ok,[],[{capabilities_read,_,true,Options}],_},p(receive_packet,[A,Query,6,Granted])),
    {ok,[],_,B1}=p(receive_packet,[A,Query,6,Granted]),
    ?assertMatch({error,_,B1},p(receive_packet,[A,Query,7,B1])),
    Bad=resign(Query,KA,fun(M) -> M#{<<"payload">> := #{<<"metrics">> => true,<<"diagnostics">> => #{<<"audio">> => true}}} end),
    ?assertMatch({error,_,Granted},p(receive_packet,[A,Bad,6,Granted])).

monitor_payload_roundtrip_with_dual_meters_and_trace_test() ->
    {A,B,_,_,SA,SB} = connected(),Policy=maps:get(policy,SB),
    Granted=SB#{policy := Policy#{members := #{A => [capabilities_read]}}},
    {ok,Q,A1}=p(request_capabilities,[B,true,5,SA]),
    {ok,[],[{capabilities_read,Id,true}],B1}=p(receive_packet,[A,Q,6,Granted]),
    Meter=#{<<"peak_db">> => -3.0,<<"rms_db">> => -6.0,<<"meter_age_ms">> => 1,<<"meter_stage">> => <<"receive_max">>},
    Base=#{<<"instance">> => binary:copy(<<"A">>,32),<<"revision">> => 0,
        <<"audio_diagnostics">> => ba_audio_diagnostics:snapshot(#{},#{})},
    lists:foreach(fun({Meters,Trace}) ->
        Caps=Base#{<<"audio_meters">> => Meters,<<"audio_trace">> => Trace},
        {ok,Reply,_}=p(reply_capabilities,[A,Id,Caps,7,B1]),
        ?assertMatch({ok,[],[{reply,<<"capabilities.reply">>,Caps}],_},p(receive_packet,[B,Reply,8,A1]))
    end,[{#{},#{}},{#{<<"receive_max">> => Meter},#{}},
        {#{<<"receive_max">> => Meter},#{<<"1">> => #{<<"stage">> => <<"mixer">>,<<"reason">> => <<"missed_packet_target">>,<<"age_ms">> => 1}}}]).

id(N) -> binary:encode_hex(<<N:128>>).
chat(Peer,N,Now,S) -> p(chat_message,[Peer,id(N),<<"text">>,Now,S]).

%% The point of the design: a request authenticates itself; nobody connects first.
requests_need_no_prior_contact_test() ->
    {A,B,_,_,SA,SB} = fixture(),
    {ok,Request,_} = p(request_status,[B,5,SA]),
    ?assertMatch({ok,[_],[authorized],_},p(receive_packet,[A,Request,6,SB])).

freshness_and_replay_test() ->
    {A,B,KA,_,SA,SB} = connected(),
    {ok,First,A1} = chat(B,1,5,SA),
    {ok,[],[{chat,_,_,_}],B1} = p(receive_packet,[A,First,6,SB]),
    ?assertMatch({error,_,B1},p(receive_packet,[A,First,7,B1])),
    {ok,Second,A2} = chat(B,2,10,A1),
    %% Outside the accepted clock difference, in either direction.
    ?assertMatch({error,_,B1},p(receive_packet,[A,Second,10+300001,B1])),
    Future = resign(Second,KA,fun(M) -> M#{<<"sent">> := maps:get(<<"sent">>,M)+300010} end),
    ?assertMatch({error,_,B1},p(receive_packet,[A,Future,11,B1])),
    ?assertMatch({ok,[],[{chat,_,_,_}],_},p(receive_packet,[A,Second,11,B1])),
    %% A restarted receiver does not accept traffic recorded before it started.
    ?assertMatch({error,_,_},p(receive_packet,[A,First,5001,p(reset,[SB,5000])])),
    %% A sender restart replaces the relationship; the old instance never returns.
    Old = maps:get(id,maps:get(A,maps:get(sessions,B1))),
    {ok,Again,_} = chat(B,3,20,p(reset,[A2,20])),
    {ok,[],[{session_replaced,Old},authorized,{chat,_,_,_}],B2} = p(receive_packet,[A,Again,21,B1]),
    {ok,Stale,_} = chat(B,4,22,A2),
    ?assertMatch({error,_,B2},p(receive_packet,[A,Stale,23,B2])).

%% Nothing is renewed in the background: an idle relationship lapses, and the
%% next authenticated request resumes it under the same instance.
idle_relationship_lapses_and_resumes_test() ->
    {A,B,_,_,SA,SB} = connected(),
    {ok,Request,A1} = p(request_status,[B,5,SA]),
    ?assertMatch({[{B,request_timeout}],_},p(expire,[5005,A1])),
    Session = maps:get(session,p(context,[A,100,SB])),
    {[{A,session_expired}],B1} = p(expire,[60004,SB]),
    ?assertError(_,p(context,[A,60004,B1])),
    ?assertMatch({[],_},p(expire,[60005,B1])),
    {ok,[_],[authorized],B2} = p(receive_packet,[A,Request,60005,B1]),
    ?assertEqual(Session,maps:get(session,p(context,[A,60005,B2]))),
    %% Not yet reported as lapsed: closed like a replaced one, then resumed.
    {ok,[_],[{session_replaced,Session},authorized],_} = p(receive_packet,[A,Request,60005,SB]),
    ?assertEqual(#{},maps:get(sessions,p(snapshot,[p(reset,[SA,0])]))).

closed_relationship_keeps_replay_state_test() ->
    {A,B,_,_,SA,SB} = connected(),
    {ok,First,_} = chat(B,1,5,SA),
    {ok,[],_,B1} = p(receive_packet,[A,First,6,SB]),
    Closed = p(close,[A,7,B1]),
    ?assertError(_,p(context,[A,7,Closed])),
    ?assertMatch({error,_,Closed},p(receive_packet,[A,First,8,Closed])).

traffic_extends_relationship_and_reports_renewal_test() ->
    {A,B,_,_,SA,SB} = connected(),
    Old = p(context,[A,100,SB]),
    {ok,Early,A1} = chat(B,1,10000,SA),
    {ok,[],[{chat,_,_,_}],B1} = p(receive_packet,[A,Early,10001,SB]),
    {ok,Later,A2} = chat(B,2,25000,A1),
    {ok,[],[{session_renewed,C},{chat,_,_,_}],B2} = p(receive_packet,[A,Later,25001,B1]),
    ?assertEqual(maps:get(session,Old),maps:get(session,C)),
    ?assertEqual(85001,maps:get(deadline,C)),
    %% Capped by the installed membership.
    {ok,Capped,_} = chat(B,3,50000,A2),
    ?assertMatch({ok,[],[{session_renewed,#{deadline := 65000}},_],_},
        p(receive_packet,[A,Capped,50001,B2#{membership_deadline => 65000}])).

simultaneous_hellos_both_complete_test() ->
    {A,B,_,_,SA,SB} = fixture(),
    {ok,HelloA,A1} = p(connect,[B,0,SA]),
    {ok,HelloB,B1} = p(connect,[A,0,SB]),
    {ok,[ReadyB],[authorized],B2} = p(receive_packet,[A,HelloA,1,B1]),
    {ok,[ReadyA],[authorized],A2} = p(receive_packet,[B,HelloB,1,A1]),
    ?assertMatch({ok,[],[],_},p(receive_packet,[B,ReadyB,2,A2])),
    ?assertMatch({ok,[],[],_},p(receive_packet,[A,ReadyA,2,B2])).

%% Session requests (rights, name, removal, End) are ordinary signed requests:
%% exact schema, the rights table, replay protection.
session_requests_are_signed_requests_test() ->
    {A,B,_,_,SA,SB} = connected(),
    Id = id(9),
    End = #{<<"kind">> => <<"ended">>},
    {ok,Packet,_} = p(session_message,[B,Id,End,5,SA]),
    ?assertMatch({error,_,SB},p(receive_packet,[A,Packet,6,SB])),
    Policy = maps:get(policy,SB),
    Moderator = SB#{policy := Policy#{members := #{A => [end_session]}}},
    {ok,[],[{session,Id,End,#{peer := A}}],Done} = p(receive_packet,[A,Packet,6,Moderator]),
    ?assertMatch({error,_,Done},p(receive_packet,[A,Packet,7,Done])),
    Ask = #{<<"kind">> => <<"privilege_release">>,<<"privilege">> => <<"stream_publish">>},
    {ok,AskPacket,_} = p(session_message,[B,id(10),Ask,8,SA]),
    ?assertMatch({ok,[],[{session,_,Ask,_}],_},p(receive_packet,[A,AskPacket,9,SB])),
    [?assertMatch({error,_,_},p(session_message,[B,id(11),Bad,8,SA])) || Bad <-
        [#{<<"kind">> => <<"privilege_release">>,<<"privilege">> => <<"root">>},
         #{<<"kind">> => <<"privilege_request">>,<<"privilege">> => <<"stream_publish">>},
         #{<<"kind">> => <<"board">>,<<"entries">> => maps:from_list([{id(N),<<"x">>} || N <- lists:seq(1,7)])},
         #{<<"kind">> => <<"note">>,<<"id">> => <<"x">>,<<"packet">> => <<"x">>},
         #{<<"kind">> => <<"rename_request">>,<<"name">> => <<>>},
         #{<<"kind">> => <<"remove_request">>,<<"device">> => <<"x">>},
         End#{<<"extra">> => true},#{<<"kind">> => <<"rpc">>}]].
