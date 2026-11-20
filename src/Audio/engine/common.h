// Engine-internal constants and helpers shared by every module.
#pragma once
#include <cstdint>
#include <stdexcept>
#include <string>

#include "engine.h"

namespace ba {
constexpr uint32_t Block = 192;  // frames per packet (4 ms at 48 kHz)
constexpr uint32_t Channels = 2;  // interleaved stereo everywhere
constexpr uint32_t Bits = 24;     // FLAC sample depth on the wire

// A command Erlang sent cannot be carried out: replied as {error, Text}.
struct CommandError : std::runtime_error {
    using std::runtime_error::runtime_error;
};
[[noreturn]] inline void fail(const std::string &text) { throw CommandError(text); }

// Unsolicited event to Erlang (thread-safe, not real-time safe).
void emit(const json &event);
}  // namespace ba
