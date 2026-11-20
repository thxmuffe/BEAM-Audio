%% Windows receiving host: the real ba_native_stream.exe from
%% scripts/platforms/Windows/build-native-stream.py, when built. No audio device
%% is opened; only the control handshake is exercised.
-module(ba_windows_native_tests).
-include_lib("eunit/include/eunit.hrl").

receiving_host_names_its_port_test_() ->
    %% Tests run from <core>/builds/intermediates/...; the helper is in <core>/builds/CLI.
    {Core,_}=lists:splitwith(fun(Part) -> Part=/="builds" end,filename:split(filename:absname(code:which(?MODULE)))),
    Helper=filename:join(Core++["builds","CLI","native-stream","ba_native_stream.exe"]),
    case {os:type(),filelib:is_regular(Helper)} of
        {{win32,_},true} -> {timeout,20,fun() -> host(Helper) end};
        _ -> []
    end.

host(Helper) ->
    Saved=[{K,os:getenv(K)} || K <- ["BA_WINDOWS_NATIVE_STREAM_HELPER","BA_NATIVE_STREAM_PORT","BA_STATE_DIR"]],
    Dir=filename:join(filename:basedir(user_cache,"BEAM-Audio"),"native-host-test"),ok=filelib:ensure_path(Dir),
    try
        os:putenv("BA_WINDOWS_NATIVE_STREAM_HELPER",Helper),os:putenv("BA_STATE_DIR",Dir),os:unsetenv("BA_NATIVE_STREAM_PORT"),
        ok=ba_windows_native_host:start(),
        Port=wait_port(50),
        {ok,S}=gen_tcp:connect({127,0,0,1},Port,[binary,{packet,4},{active,false}],2000),
        G=binary:copy(<<"d">>,32),
        ok=gen_tcp:send(S,json:encode(#{op => <<"hello">>,version => 2,generation => G})),
        {ok,B}=gen_tcp:recv(S,0,5000),
        ?assertMatch(#{<<"event">> := <<"hello">>,<<"profile">> := <<"gst_aac_rtp_v2">>,<<"generation">> := G},json:decode(B)),
        gen_tcp:close(S),
        %% Stopping the owner stops the helper and withdraws the port.
        Pid=whereis(ba_windows_native_host),Ref=monitor(process,Pid),
        ok=gen_server:stop(Pid),receive {'DOWN',Ref,process,Pid,_} -> ok end,
        ?assertEqual(false,os:getenv("BA_NATIVE_STREAM_PORT"))
    after
        case whereis(ba_windows_native_host) of undefined -> ok;P -> gen_server:stop(P) end,
        [case V of false -> os:unsetenv(K);_ -> os:putenv(K,V) end || {K,V} <- Saved]
    end.

wait_port(0) -> error(native_host_port_missing);
wait_port(N) ->
    case os:getenv("BA_NATIVE_STREAM_PORT") of
        false -> timer:sleep(100),wait_port(N-1);
        P -> list_to_integer(P)
    end.
