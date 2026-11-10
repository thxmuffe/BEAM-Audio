-module(ba_device_web_cli).
-export([main/0]).

main() ->
    try
        {Options,Open}=options(init:get_plain_arguments(),#{},false),
        case maps:get(mode,Options,device)=:=preview orelse maps:is_key(record,Options) of
            true -> ok;
            false -> error(missing_mode)
        end,
        application:set_env(ba_device_web,options,Options),
        {ok,_}=application:ensure_all_started(ba_device_web),
        URL=binary_to_list(ba_device_web_sup:origin()),
        io:format("BEAM Audio: ~s (~p)~nPress Control-C to stop.~n",[URL,maps:get(mode,Options,device)]),
        case Open of true -> open_browser(URL);false -> ok end,
        receive shutdown -> application:stop(ba_device_web),halt() end
    catch _:_ ->
        io:format(standard_error,"Cannot start Device Web. Use --assets DIR [--port PORT] (--preview | --device-record FILE) [--open].~nCheck that the port is free and the paths/options are valid.~n",[]),
        halt(1)
    end.

options([],Options,Open) -> {Options,Open};
options(["--assets",Path|Rest],Options,Open) ->
    true=filelib:is_dir(Path),options(Rest,Options#{assets => filename:absname(Path)},Open);
options(["--port",Port|Rest],Options,Open) ->
    N=list_to_integer(Port),true=N>=0 andalso N=<65535,options(Rest,Options#{port => N},Open);
options(["--preview"|Rest],Options,Open) ->
    false=maps:is_key(record,Options),options(Rest,Options#{mode => preview},Open);
options(["--device-record",Path|Rest],Options,Open) ->
    false=maps:get(mode,Options,device)=:=preview,
    options(Rest,Options#{record => filename:absname(Path)},Open);
options(["--open"|Rest],Options,_) -> options(Rest,Options,true).

open_browser(URL) ->
    %% URL is generated from our numeric loopback port, never user shell input.
    case os:type() of
        {unix,darwin} -> os:cmd("open "++URL);
        {win32,_} -> os:cmd("cmd /c start \"\" "++URL);
        {unix,_} -> os:cmd("xdg-open "++URL)
    end.
