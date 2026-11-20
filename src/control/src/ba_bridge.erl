%% Shared JSON interface for native hosts. request/1 is transport-independent.
%% macOS main/0 uses app-owned stdin/stdout pipes, never a network listener.
-module(ba_bridge).
-export([main/0, request/1, file_log/0]).

main() ->
    logger:update_handler_config(default, config, #{type => standard_error}),
    file_log(),
    io:setopts(standard_io, [binary, {encoding, utf8}]),
    {ok, _} = ba_runtime:start(),
    loop().

loop() ->
    case io:get_line(standard_io, "") of
        eof -> close_session(),init:stop();
        {error, _} -> init:stop(1);
        Line ->
            io:put_chars(standard_io, [request(Line), $\n]),
            loop()
    end.

%% Every Device also logs to runtime.log in its own state folder, as the CLI
%% does, so problems can be read after the fact (bounded, rotated).
file_log() ->
    case ba_settings:env("BA_STATE_DIR") of
        false -> ok;
        Dir -> _ = logger:add_handler(state_file,logger_std_h,#{config => #{type => file,
                    file => filename:join(Dir,"runtime.log"),max_no_bytes => 1000000,max_no_files => 3}}),ok
    end.

%% An embedded host can call request/1 without emulating terminal I/O.
%% The single gate for app windows: the page's commands (ba_device_api's list)
%% and the two the native host itself sends.
request(JSON) when is_binary(JSON) ->
    Request=try json:decode(JSON) catch _:_ -> #{} end,
    Allowed=lists:member(maps:get(<<"method">>,Request,<<"snapshot">>),
                         ba_device_api:client_methods()++[<<"network_changed">>,<<"audio_lifecycle">>]),
    Reply=try case Allowed of
              true -> ba_sessions:request(Request);
              false -> maps:merge(#{<<"error">> => <<"Unsupported command.">>},maps:with([<<"request_id">>],Request))
          end
          catch _:_ -> maps:merge(#{<<"error">> => <<"Session runtime unavailable.">>},
                                  maps:with([<<"request_id">>],Request)) end,
    iolist_to_binary(json:encode(Reply));
request(JSON) -> request(iolist_to_binary(JSON)).

close_session() ->
    case whereis(ba_session) of undefined -> ok;_ -> try ba_session:disconnect() catch exit:_ -> ok end end.
