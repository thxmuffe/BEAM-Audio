-module(ba_device_web_cli).
-export([main/0,windows_main/0]).

%% Windows audio uses ba_native_stream.exe when BA_WINDOWS_NATIVE_STREAM_HELPER names it.
windows_main() ->
    os:putenv("BA_PLATFORM","windows"),
    main().

main() ->
    try
        {Options,Open}=options(init:get_plain_arguments(),#{},false),
        case maps:get(mode,Options,device)=:=preview orelse maps:is_key(record,Options) orelse maps:get(local_device,Options,false) of
            true -> ok;
            false -> error(missing_mode)
        end,
        true=not maps:get(monitor,Options,false) orelse maps:get(local_device,Options,false),
        true=not (maps:get(app,Options,false) andalso maps:get(monitor,Options,false)),
        case maps:get(local_device,Options,false) of
            true ->
                {ok,_}=application:ensure_all_started(crypto),
                %% Launchers own persistent identity storage. Never silently
                %% replace a Device with a fresh key and temporary state.
                case {ba_settings:env("BA_STATE_DIR"),ba_settings:env("BA_IDENTITY_SEED")} of
                    {D,K} when is_list(D),D=/=[],is_list(K),length(K)=:=64 ->
                        32=byte_size(binary:decode_hex(list_to_binary(K)));
                    _ ->
                        io:put_chars(standard_error,"A local Device needs persistent BA_STATE_DIR and BA_IDENTITY_SEED. Use the platform app launcher or attach with --device-record.\n"),
                        error(missing_persistent_identity)
                end,
                os:putenv("BA_DEVICE_NAME",ba_settings:env("BA_DEVICE_NAME",ba_device_label:os_name())),
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
        Browser=case Open of true -> open_browser(URL,maps:get(app,Options,false));false -> none end,
        case maps:get(monitor,Options,false) of
            true ->
                {Pid,Ref}=spawn_monitor(fun() -> ba_cli_monitor:run_local(#{all => true}) end),
                receive
                    {'DOWN',Ref,process,Pid,_} ->
                        io:put_chars(standard_error,"Monitor stopped; Device and web app remain running.\n"),
                        receive shutdown -> ok end;
                    shutdown -> ok
                end;
            false -> receive
                shutdown -> ok;
                {Browser,{exit_status,0}} when is_port(Browser) -> ok;
                {Browser,{exit_status,Code}} when is_port(Browser) -> error({browser_failed,Code})
            end
        end,
        application:stop(ba_device_web),
        case maps:get(local_device,Options,false) of
            true -> ok=ba_settings:flush(),application:stop(ba_core);
            false -> ok
        end,
        halt()
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
options(["--app"|Rest],Options,_) ->
    options(Rest,Options#{app => true},true);
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

open_browser(URL,App) ->
    %% URL is generated from our numeric loopback port, never user shell input.
    case os:type() of
        {unix,darwin} -> os:cmd("open "++URL);
        {win32,_} -> windows_browser(URL,App);
        {unix,_} -> os:cmd("xdg-open "++URL)
    end.

%% Windows app window: a private Chrome/Edge process for this Device, so the
%% window's exit ends the Device. BA_WEB_BROWSER names another executable (or a
%% test stand-in). The browser never inherits the identity seed.
windows_browser(URL,true) ->
    Chrome="Google\\Chrome\\Application\\chrome.exe",Edge="Microsoft\\Edge\\Application\\msedge.exe",
    case browser([Chrome,Edge]) of
        false -> io:put_chars(standard_error,"Install Microsoft Edge or Google Chrome to open the Windows app.\n"),error(no_browser);
        Browser ->
            State=ba_settings:env("BA_STATE_DIR"),true=is_list(State),
            Profile=filename:nativename(filename:join(State,"browser")),
            %% OTP refuses to spawn .cmd/.bat files; a .py stand-in runs under Python.
            {Executable,Prefix}=case string:lowercase(filename:extension(Browser)) of
                ".py" -> {os:find_executable("python"),[Browser]};
                _ -> {Browser,[]}
            end,
            open_port({spawn_executable,Executable},[{args,Prefix++["--app="++URL,"--user-data-dir="++Profile,"--no-first-run",
                "--no-default-browser-check","--disable-background-mode"]},{env,ba_native_env:without_secrets()},exit_status])
    end;
windows_browser(URL,false) ->
    case browser(["Google\\Chrome\\Application\\chrome.exe"]) of
        false -> os:cmd("cmd /c start \"\" "++URL);
        Chrome -> open_port({spawn_executable,Chrome},[{args,[URL]},{env,ba_native_env:without_secrets()}]),ok
    end.
browser(Relative) ->
    case ba_settings:env("BA_WEB_BROWSER") of
        false ->
            Found=[Path || R <- Relative,Var <- ["ProgramFiles","ProgramFiles(x86)","LOCALAPPDATA"],
                Base <- [os:getenv(Var)],is_list(Base),Path <- [filename:join(Base,R)],filelib:is_regular(Path)],
            case Found of [First|_] -> First;[] -> false end;
        Path -> Path
    end.
