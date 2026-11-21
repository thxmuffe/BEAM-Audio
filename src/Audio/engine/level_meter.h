#pragma once

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdint>

#include "engine.h"

namespace ba {
// One producer per signal. Publish peak, RMS and sample time together without
// taking a lock in a device callback. The reader builds the control message.
class LevelMeter {
   public:
    void sample(const float *samples, uint32_t count, uint64_t now_ns) {
        if (!count) return;
        float peak = 0;
        double squares = 0;
        for (uint32_t i = 0; i < count; ++i) {
            const float amplitude = std::abs(samples[i]);
            if (!std::isfinite(amplitude)) continue;
            peak = std::max(peak, amplitude);
            squares += double(amplitude) * amplitude;
        }
        store(peak, std::sqrt(squares / count), now_ns);
    }

    void clear() { value_.store(0, std::memory_order_relaxed); }

    json read(uint64_t now_ns) const {
        const uint64_t value = value_.load(std::memory_order_relaxed);
        const uint32_t age = uint32_t(now_ns / 1000000) - uint32_t(value >> 32);
        if (!value || age > 1000) return nullptr;
        return {{"peak_db", decode(uint16_t(value >> 16))}, {"rms_db", decode(uint16_t(value))}, {"meter_age_ms", age}};
    }

   private:
    static uint16_t encode(double amplitude) {
        const double db = 20 * std::log10(std::max(amplitude, 0.00001584893192461114));
        return uint16_t(std::lround((std::clamp(db, -96.0, 48.0) + 96) * 100)) + 1;
    }

    static double decode(uint16_t value) { return (value - 1) / 100.0 - 96; }

    void store(double peak, double rms, uint64_t now_ns) {
        const uint64_t time_ms = uint32_t(now_ns / 1000000);
        value_.store((time_ms << 32) | (uint64_t(encode(peak)) << 16) | encode(rms), std::memory_order_relaxed);
    }

    static_assert(std::atomic<uint64_t>::is_always_lock_free);
    std::atomic<uint64_t> value_{0};
};
}  // namespace ba
