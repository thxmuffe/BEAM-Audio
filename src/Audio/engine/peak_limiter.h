#pragma once

#include <algorithm>
#include <cmath>
#include <cstdint>

namespace ba {
// One gain for all channels in a render block. Reduce immediately to keep
// sample peaks in range, then gradually restore unity as peaks recede.
class PeakLimiter {
   public:
    float apply(float *samples, uint32_t frames, uint32_t channels, uint32_t rate) {
        const uint32_t count = frames * channels;
        float peak = 0.0f;
        for (uint32_t i = 0; i < count; ++i) peak = std::max(peak, std::abs(samples[i]));

        const float ceiling_gain = peak > 1.0f ? 1.0f / peak : 1.0f;
        constexpr float ReleaseSeconds = 0.15f;
        gain_ = std::min(ceiling_gain, gain_ + float(frames) / (rate * ReleaseSeconds));
        if (gain_ < 1.0f) {
            for (uint32_t i = 0; i < count; ++i) samples[i] *= gain_;
        }
        return gain_;
    }

   private:
    float gain_ = 1.0f;
};
}  // namespace ba
