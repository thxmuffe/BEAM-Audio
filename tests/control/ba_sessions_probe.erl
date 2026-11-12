%% Disposable integration harness; never packaged in the runtime.
-module(ba_sessions_probe).
-export([main/0,loop/0]).
main() ->
 application:load(ba_core),application:set_env(ba_core,runtime_profile,buffee_control),application:set_env(ba_core,restore_buffee_on_start,true),
 application:set_env(ba_core,audio_automation,false),application:set_env(ba_core,buffee_default_permissions,ba_app_session:permissions()),application:set_env(ba_core,clock_reference,system),
 logger:set_primary_config(level,critical),{ok,_}=application:ensure_all_started(ba_core),loop().
loop() -> case io:get_line("") of eof -> halt();L ->
 try json:decode(unicode:characters_to_binary(L)) of
  #{<<"method">> := <<"connections">>} -> emit(#{count => map_size(ba_desk_connections_sup:connections())});
  Command -> emit(ba_sessions:request(Command))
 catch C:R:St -> emit(#{error => iolist_to_binary(io_lib:format("~p:~p ~p",[C,R,St]))}) end,loop() end.
emit(R) -> io:put_chars([json:encode(R),"\n"]).
