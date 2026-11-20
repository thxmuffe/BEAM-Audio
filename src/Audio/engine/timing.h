// Session timing: the clock mapping Erlang supplies, the servo that keeps a
// device position on the Session timeline, and a bounded error summary.
#pragma once
#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdint>

#include "common.h"

namespace ba {
constexpr double JumpSeconds = 0.02;  // beyond this, re-position instead of slewing

// session_ns = session0 + (host - host0) * rate; read from real-time threads.
class Clock {
    std::atomic<uint32_t> seq_{0};
    std::atomic<int64_t> host0_{0}, session0_{0};
    std::atomic<double> rate_{1.0};
    std::atomic<bool> ready_{false};

   public:
    bool map(uint64_t host, int64_t &session) const {
        for (;;) {
            const uint32_t s = seq_.load(std::memory_order_acquire);
            if (s & 1) continue;
            const bool ready = ready_.load(std::memory_order_relaxed);
            const int64_t h0 = host0_.load(std::memory_order_relaxed), s0 = session0_.load(std::memory_order_relaxed);
            const double rate = rate_.load(std::memory_order_relaxed);
            std::atomic_thread_fence(std::memory_order_acquire);
            if (seq_.load(std::memory_order_relaxed) != s) continue;
            if (!ready) return false;
            session = s0 + int64_t(std::llround(double(int64_t(host) - h0) * rate));
            return true;
        }
    }
    // The first mapping sets the offset; later ones keep Session time continuous
    // at "now" and change only the rate (Erlang's correction converges slowly).
    void update(int64_t internal, int64_t session, double ppm) {
        int64_t h0 = internal, s0 = session;
        if (ready_.load()) {
            h0 = int64_t(host_now_ns());
            map(uint64_t(h0), s0);
        }
        seq_.fetch_add(1, std::memory_order_acq_rel);
        host0_.store(h0, std::memory_order_relaxed);
        session0_.store(s0, std::memory_order_relaxed);
        rate_.store(1.0 + ppm * 1e-6, std::memory_order_relaxed);
        ready_.store(true, std::memory_order_relaxed);
        seq_.fetch_add(1, std::memory_order_release);
    }
    bool ready() const { return ready_.load(); }
};

// Keeps a device position on the Session timeline by nudging the resampler ratio.
struct Servo {
    static constexpr double Kp = 1e-5, Ki = 2e-8, Max = 1e-3;
    double filtered = 0, integral = 0;
    bool primed = false;
    void reset() { filtered = integral = 0, primed = false; }
    // error: device position minus desired position, in stream samples.
    double correction(double error) {
        filtered = primed ? filtered + 0.05 * (error - filtered) : error;
        primed = true;
        integral = std::clamp(integral + filtered, -Max / Ki, Max / Ki);
        return std::clamp(Kp * filtered + Ki * integral, -Max, Max);
    }
};

// Timing error summary: written by one real-time thread, taken by status.
struct ErrorWindow {
    std::atomic<int64_t> max_ns{0}, sum_ns{0};
    std::atomic<uint64_t> count{0};
    void add(int64_t ns) {
        const int64_t a = ns < 0 ? -ns : ns;
        if (a > max_ns.load(std::memory_order_relaxed)) max_ns.store(a, std::memory_order_relaxed);
        sum_ns.fetch_add(a, std::memory_order_relaxed);
        count.fetch_add(1, std::memory_order_relaxed);
    }
    json take() {
        const uint64_t n = count.exchange(0);
        const int64_t sum = sum_ns.exchange(0), max = max_ns.exchange(0);
        return {{"samples", n}, {"max_us", double(max) / 1000.0}, {"mean_us", n ? double(sum) / double(n) / 1000.0 : 0.0}};
    }
};
}  // namespace ba
