%% Shared Windows binding setup for native and browser-hosted Devices.
%% No hardware is opened here; the shared Device consent/automation owns that.
-module(ba_windows_device).
-export([boot/0,configure/1]).

boot() ->
    configure(os:getenv("BA_WINDOWS_AUDIO_HELPER_DIR")),
    ba_device_web_cli:main().

configure(Directory) when is_list(Directory),Directory=/=[] ->
    os:putenv("BA_PLATFORM","windows"),
    os:putenv("BA_WINDOWS_AUDIO_OUTPUT_HELPER",filename:join(Directory,"ba_audio_output.exe")),
    os:putenv("BA_WINDOWS_AUDIO_CAPTURE_HELPER",filename:join(Directory,"ba_audio_capture.exe")),
    ok.
