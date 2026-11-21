// BEAM Audio engine: executes Erlang's instructions on audio and packets.
// Erlang decides (ports, peers, keys, clock, stream anchors); this code never
// does. Platform shells own the OS devices and call the two C functions below
// from their real-time callbacks. See docs/AUDIO_ENGINE.md.
#pragma once
#include <cstdint>
#include <string>

#include <nlohmann/json.hpp>

// Real-time entry points for platform shells. Interleaved stereo float32.
// host_time_ns: when the first frame reaches the speaker (render) or was
// captured (capture), on the host clock that ba::host_now_ns() reads.
// Never allocate, lock or throw in these.
extern "C" {
void ba_engine_render(float *out, uint32_t frames, uint64_t host_time_ns);
// slot: the capture the engine named in Shell::start_capture (several at once).
void ba_engine_capture(int slot, const float *in, uint32_t frames, uint64_t host_time_ns);
}

namespace ba {
using json = nlohmann::json;

// Implemented by each platform shell.
uint64_t host_now_ns();
struct Shell {
    virtual ~Shell() = default;
    // Starts the default output device; returns its sample rate.
    virtual uint32_t start_output() = 0;
    virtual void stop_output() = 0;
    // source: "system" (OS output tap), "mic", "tone" (test signal). Several
    // captures run at once, each in its own slot. Returns the capture sample
    // rate; frames arrive through ba_engine_capture(slot, ...).
    virtual uint32_t start_capture(int slot, const std::string &source) = 0;
    virtual void stop_capture(int slot) = 0;
    // direction: "previous", "next" or "playpause".
    virtual json playback_step(const std::string &) { return {{"status", "unsupported"}}; }
};

// Port program (macOS, Windows, Linux): serves Erlang on stdin/stdout as OTP
// {packet,4} term frames until the port closes. Returns the exit status.
int run(Shell &shell, int argc, const char **argv);
// In-process engine (iOS, where apps cannot start programs): serves one Erlang
// owner at a time on a 127.0.0.1 TCP port, returned here; the same frames.
// A closed connection releases every stream; the engine waits for the next.
uint16_t serve_loopback(Shell &shell, const char *crash_file);

// Crash reporting (crash.cpp): fatal signals, std::terminate.
void install_crash_handlers(const char *crash_file);
void remember_command(const std::string &text);
}  // namespace ba
