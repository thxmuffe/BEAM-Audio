-module(ba_device_web_tests).
-include_lib("eunit/include/eunit.hrl").

web_test_() ->
    {setup,fun setup/0,fun cleanup/1,fun(C) ->
        [?_test(session_and_assets(C)),
         ?_test(origin_and_token(C)),
         ?_test(command_boundary(C)),
         ?_test(preview_is_isolated(C)),
         ?_test(socket_bridge(C)),
         ?_test(direct_device(C)),
         ?_test(listener_lifecycle(C))]
    end}.

setup() ->
    %% Tests use their own assets/state; no OpenSound checkout, Desk or hardware.
    Root=filename:absname("../../.."),
    true=code:add_patha(filename:join(Root,"builds/intermediates/control/default/lib/ba_core/ebin")),
    {ok,_}=application:ensure_all_started(inets),
    {ok,_}=application:ensure_all_started(cowboy),
    Dir=filename:join([Root,"builds/intermediates/DeviceWeb",
        "test-"++integer_to_list(erlang:unique_integer([positive]))]),
    ok=filelib:ensure_dir(filename:join(Dir,"index.html")),
    ok=file:write_file(filename:join(Dir,"index.html"),<<"<!doctype html><title>Test UI</title>">>),
    ok=file:write_file(filename:join(Dir,"state.mjs"),<<"export const test = true;">>),
    ok=file:write_file(filename:join(Dir,"private.json"),<<"private">>),
    #{dir => Dir}.

cleanup(#{dir := Dir}) ->
    application:stop(ba_device_web),application:stop(ba_core),
    file:del_dir_r(Dir).

start(#{dir := Dir},Extra) ->
    application:stop(ba_device_web),
    application:set_env(ba_device_web,options,maps:merge(#{port => 0,assets => Dir},Extra)),
    {ok,_}=application:ensure_all_started(ba_device_web),
    binary_to_list(ba_device_web_sup:origin()).

request(URL,Method,Path,Body,Headers) ->
    Request=case Method of
        get -> {URL++Path,Headers};
        post -> {URL++Path,Headers,"application/json",Body}
    end,
    {ok,{{_,Code,_},ResponseHeaders,Response}}=
        httpc:request(Method,Request,[{timeout,4000}],[{body_format,binary}]),
    {Code,ResponseHeaders,Response}.
get(URL,Path) -> request(URL,get,Path,<<>>,[]).
token(URL) ->
    {200,_,Body}=get(URL,"/api/session"),maps:get(<<"token">>,json:decode(Body)).
post(URL,Command) ->
    request(URL,post,"/api/command",json:encode(Command),
        [{"x-beam-audio-token",binary_to_list(token(URL))}]).
status({Code,_,_}) -> Code.

session_and_assets(C) ->
    URL=start(C,#{}),
    {200,_,Session}=get(URL,"/api/session"),
    ?assertEqual(<<"device">>,maps:get(<<"mode">>,json:decode(Session))),
    {200,Headers,_}=get(URL,"/state.mjs"),
    ?assertEqual("application/javascript",proplists:get_value("content-type",Headers)),
    ?assertEqual("no-store",proplists:get_value("cache-control",Headers)),
    ?assert(string:find(proplists:get_value("content-security-policy",Headers),"frame-ancestors 'none'")=/=nomatch),
    lists:foreach(fun(Path) -> ?assertEqual(404,status(get(URL,Path))) end,
        ["/private.json","/../private.json","/%2e%2e/private.json","/.hidden.js","/api/nodes","/nested/state.mjs"]),
    ?assertEqual(503,status(post(URL,#{method => snapshot}))).

origin_and_token(C) ->
    URL=start(C,#{}),Token=binary_to_list(token(URL)),
    ?assertEqual(403,status(request(URL,post,"/api/command",<<"{}">>,[]))),
    ?assertEqual(403,status(request(URL,post,"/api/command",<<"{}">>,[{"x-beam-audio-token","wrong"}]))),
    ?assertEqual(403,status(request(URL,get,"/api/session",<<>>,[{"host","attacker.example"}]))),
    ?assertEqual(403,status(request(URL,get,"/api/session",<<>>,[{"origin","https://other.example"}]))),
    ?assertEqual(403,status(request(URL,post,"/api/command",<<"{}">>,
        [{"x-beam-audio-token",Token},{"sec-fetch-site","cross-site"}]))).

command_boundary(C) ->
    URL=start(C,#{}),Token=binary_to_list(token(URL)),
    lists:foreach(fun(Command) -> ?assertEqual(400,status(post(URL,Command))) end,
        [#{method => kill},#{method => stop},#{method => snapshot,instance => <<"injected">>},
         #{method => #{}},[],#{method => <<"arbitrary_rpc">>}]),
    ?assertEqual(400,status(request(URL,post,"/api/command",<<"{broken">>,[{"x-beam-audio-token",Token}]))),
    ?assertEqual(413,status(post(URL,#{method => snapshot,padding => binary:copy(<<"x">>,17000)}))),
    {ok,{{_,415,_},_,_}}=httpc:request(post,
        {URL++"/api/command",[{"x-beam-audio-token",Token}],"text/plain","{}"},[],[]),
    %% Chunked transfer has no Content-Length; the actual body is still bounded.
    Port=list_to_integer(lists:last(string:split(URL,":",all))),
    {ok,S}=gen_tcp:connect({127,0,0,1},Port,[binary,{active,false}],1000),
    try
        ok=gen_tcp:send(S,["POST /api/command HTTP/1.1\r\nHost: 127.0.0.1:",integer_to_list(Port),
            "\r\nContent-Type: application/json\r\nX-BEAM-Audio-Token: ",Token,
            "\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n4268\r\n",
            binary:copy(<<"x">>,17000),"\r\n0\r\n\r\n"]),
        {ok,Reply}=gen_tcp:recv(S,0,3000),
        ?assertMatch(<<"HTTP/1.1 413",_/binary>>,Reply)
    after gen_tcp:close(S) end.

preview_is_isolated(C) ->
    %% Even an invalid supplied socket record is never read in preview mode.
    URL=start(C,#{mode => preview,record => "does-not-exist"}),
    {200,_,Session}=get(URL,"/api/session"),
    ?assertEqual(<<"preview">>,maps:get(<<"mode">>,json:decode(Session))),
    ?assertEqual(409,status(post(URL,#{method => create_swarm}))).

socket_bridge(#{dir := Dir}=C) ->
    %% Unix-domain socket paths have a short OS limit; checkout paths may exceed it.
    Path="/tmp/ba-device-web-"++integer_to_list(erlang:unique_integer([positive]))++".sock",
    Record=filename:join(Dir,"running.json"),
    {ok,L}=gen_tcp:listen(0,[local,binary,{ifaddr,{local,Path}},{packet,line},{active,false}]),
    ok=file:write_file(Record,json:encode(#{socket => Path,instance => <<"private-instance">>})),
    Parent=self(),
    Worker=spawn_monitor(fun() ->
        {ok,S}=gen_tcp:accept(L,3000),
        {ok,Bytes}=gen_tcp:recv(S,0,3000),
        Parent ! {received,json:decode(Bytes)},
        ok=gen_tcp:send(S,[json:encode(#{error => null,device => <<"test-device">>,
            managed => #{name => <<"Studio">>,instance => <<"private-instance">>,os_pid => <<"123">>}}),$\n]),
        gen_tcp:close(S)
    end),
    try
        URL=start(C,#{record => Record}),
        {200,_,Body}=post(URL,#{method => snapshot,request_id => <<"ui-request">>}),
        Reply=json:decode(Body),
        ?assertEqual(<<"test-device">>,maps:get(<<"device">>,Reply)),
        ?assertEqual(#{<<"name">> => <<"Studio">>},maps:get(<<"managed">>,Reply)),
        receive {received,Seen} ->
            ?assertEqual(<<"private-instance">>,maps:get(<<"instance">>,Seen)),
            ?assertEqual(<<"ui-request">>,maps:get(<<"request_id">>,Seen))
        after 3000 -> error(no_socket_request) end,
        {Pid,Ref}=Worker,
        receive {'DOWN',Ref,process,Pid,normal} -> ok after 3000 -> error(socket_worker_failed) end,
        %% A changed running record must not silently reuse the old credential.
        ok=file:write_file(Record,<<"invalid">>),
        ?assertEqual(503,status(post(URL,#{method => snapshot})))
    after gen_tcp:close(L),file:delete(Path) end.

direct_device(#{dir := Dir}=C) ->
    Old=[{K,os:getenv(K)} || K <- ["BA_STATE_DIR","BA_IDENTITY_SEED","BA_RECEPTION_DESK_URL"]],
    os:putenv("BA_STATE_DIR",Dir),
    os:putenv("BA_IDENTITY_SEED",binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(32)))),
    os:putenv("BA_RECEPTION_DESK_URL",""),
    application:load(ba_core),
    application:set_env(ba_core,audio_automation,false),
    application:set_env(ba_core,audio_consent,#{speaker => false,microphone => false,broadcast => false}),
    try
        {ok,_}=ba_runtime:start(swarm_control),
        URL=start(C,#{}),
        {200,_,Body}=post(URL,#{method => snapshot}),
        Snapshot=json:decode(Body),
        ?assertEqual(<<"idle">>,maps:get(<<"state">>,maps:get(<<"swarm">>,Snapshot))),
        ?assertNot(maps:is_key(<<"managed">>,Snapshot)),
        {200,_,Changed}=post(URL,#{method => capability,capability => microphone,enabled => true}),
        ?assertEqual(true,maps:get(<<"microphone">>,maps:get(<<"consent">>,json:decode(Changed)))),
        ?assertEqual(true,maps:get(microphone,ba_device_config:consent())),
        ?assertEqual(undefined,whereis(ba_device_handler)),
        {200,_,Undone}=post(URL,#{method => undo}),
        ?assertEqual(false,maps:get(<<"microphone">>,maps:get(<<"consent">>,json:decode(Undone))))
    after
        application:stop(ba_core),
        lists:foreach(fun({K,false}) -> os:unsetenv(K);({K,V}) -> os:putenv(K,V) end,Old)
    end.

listener_lifecycle(C) ->
    URL=start(C,#{}),OldToken=token(URL),
    %% The listener is supervised beneath the optional application.
    [{_,Pid,supervisor,_}]=supervisor:which_children(ba_device_web_sup),
    Ref=erlang:monitor(process,Pid),
    ok=application:stop(ba_device_web),
    receive {'DOWN',Ref,process,Pid,_} -> ok after 1000 -> error(listener_survived_stop) end,
    ?assertMatch({error,_},httpc:request(get,{URL++"/api/session",[]},[{timeout,500}],[])),
    NewURL=start(C,#{}),
    ?assertNotEqual(OldToken,token(NewURL)),
    ?assertEqual(403,status(request(NewURL,post,"/api/command",<<"{}">>,
        [{"x-beam-audio-token",binary_to_list(OldToken)}]))).
