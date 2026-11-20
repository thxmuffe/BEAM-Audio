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
void ba_engine_capture(const float *in, uint32_t frames, uint64_t host_time_ns);
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
    // source: "system" (OS output tap), "tone" (test signal). Returns the
    // capture sample rate; frames arrive through ba_engine_capture.
    virtual uint32_t start_capture(const std::string &source) = 0;
    virtual void stop_capture() = 0;
};

// Runs the engine until stdin closes: control messages in, events out, both
// as OTP {packet,4} JSON frames. Returns the process exit status.
int run(Shell &shell, int argc, const char **argv);

// Crash reporting (crash.cpp): fatal signals, std::terminate.
void install_crash_handlers(const char *crash_file);
void remember_command(const std::string &text);
}  // namespace ba
