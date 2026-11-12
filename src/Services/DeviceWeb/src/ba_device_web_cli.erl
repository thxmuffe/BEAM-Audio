-module(ba_device_web_cli).
-export([main/0]).

main() ->
    try
        {Options,Open}=options(init:get_plain_arguments(),#{},false),
        case maps:get(mode,Options,device)=:=preview orelse maps:is_key(record,Options) orelse maps:get(local_device,Options,false) of
            true -> ok;
            false -> error(missing_mode)
        end,
        true=not maps:get(monitor,Options,false) orelse maps:get(local_device,Options,false),
        case maps:get(local_device,Options,false) of
            true ->
                {ok,_}=application:ensure_all_started(crypto),
                %% Launchers may supply the Device's persistent platform identity.
                case {os:getenv("BA_STATE_DIR"),os:getenv("BA_IDENTITY_SEED")} of
                    {D,K} when is_list(D),is_list(K) -> ok;
                    _ ->
                        Temp=case os:getenv("TEMP") of false -> ".";T -> T end,
                        Dir=filename:join(Temp,"beamaudio-web-"++binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(8)))),
                        ok=filelib:ensure_dir(filename:join(Dir,"state")),os:putenv("BA_STATE_DIR",Dir),
                        os:putenv("BA_IDENTITY_SEED",binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(32))))
                end,
                os:putenv("BA_DEVICE_NAME",os:getenv("BA_DEVICE_NAME",ba_device_label:os_name())),
                application:load(ba_core),
                application:set_env(ba_core,restore_buffee_on_start,true),
                application:set_env(ba_core,buffee_default_permissions,ba_app_session:permissions()),
                application:set_env(ba_core,audio_consent,#{speaker => false,microphone => false,broadcast => false}),
                {ok,_}=ba_runtime:start(buffee_control);
            false -> ok
        end,
        application:set_env(ba_device_web,options,Options),
        {ok,_}=application:ensure_all_started(ba_device_web),
        URL=binary_to_list(ba_device_web_sup:origin()),
        io:format("BEAM Audio: ~s (~p)~nPress Control-C to stop.~n",[URL,maps:get(mode,Options,device)]),
        case Open of true -> open_browser(URL);false -> ok end,
        case maps:get(monitor,Options,false) of
            true ->
                {Pid,Ref}=spawn_monitor(fun() -> ba_cli_monitor:run_local(#{all => true}) end),
                receive
                    {'DOWN',Ref,process,Pid,_} ->
                        io:put_chars(standard_error,"Monitor stopped; Device and web app remain running.\n"),
                        receive shutdown -> ok end;
                    shutdown -> ok
                end;
            false -> receive shutdown -> ok end
        end,
        application:stop(ba_device_web),halt()
    catch _:_ ->
        io:format(standard_error,"Cannot start Device Web. Use --assets DIR [--port PORT] (--local-device | --preview | --device-record FILE) [--open].~nCheck that the port is free and the paths/options are valid.~n",[]),
        halt(1)
    end.

options([],Options,Open) -> {Options,Open};
options(["--assets",Path|Rest],Options,Open) ->
    true=filelib:is_dir(Path),options(Rest,Options#{assets => filename:absname(Path)},Open);
options(["--port",Port|Rest],Options,Open) ->
    N=list_to_integer(Port),true=N>=0 andalso N=<65535,options(Rest,Options#{port => N},Open);
options(["--monitor"|Rest],Options,Open) ->
    options(Rest,Options#{monitor => true},Open);
options(["--local-device"|Rest],Options,Open) ->
    false=maps:is_key(record,Options),
    false=maps:get(mode,Options,device)=:=preview,
    options(Rest,Options#{local_device => true},Open);
options(["--preview"|Rest],Options,Open) ->
    false=maps:is_key(record,Options),false=maps:get(local_device,Options,false),options(Rest,Options#{mode => preview},Open);
options(["--device-record",Path|Rest],Options,Open) ->
    false=maps:get(mode,Options,device)=:=preview,false=maps:get(local_device,Options,false),
    options(Rest,Options#{record => filename:absname(Path)},Open);
options(["--open"|Rest],Options,_) -> options(Rest,Options,true).

open_browser(URL) ->
    %% URL is generated from our numeric loopback port, never user shell input.
    case os:type() of
        {unix,darwin} -> os:cmd("open "++URL);
        {win32,_} ->
            Script=os:getenv("BA_WEB_BROWSER_SCRIPT"),
            case Script of
                false -> os:cmd("cmd /c start \"\" "++URL);
                _ ->
                    Port=open_port({spawn_executable,os:getenv("BA_WEB_POWERSHELL")},
                        [{args,["-NoLogo","-NoProfile","-ExecutionPolicy","Bypass","-File",Script,URL]},exit_status,hide]),
                    receive {Port,{exit_status,_}} -> ok after 10000 -> port_close(Port) end
            end;
        {unix,_} -> os:cmd("xdg-open "++URL)
    end.
