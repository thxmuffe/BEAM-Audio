// The iPhone app starts the audio engine inside its own process (iOS apps
// cannot start programs). Erlang connects to the returned 127.0.0.1 port.
#pragma once
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif
// Starts the engine once; returns its control port, or 0 on failure. A crash
// report is written to crash_file and posted to chat on the next launch.
uint16_t ba_audio_engine_start(const char *crash_file);
#ifdef __cplusplus
}
#endif
