// Lost-packet recovery. A receiver notices gaps in a stream's RTP sequence
// numbers and asks its sender again (NACK, at most three times, 30 ms apart);
// the sender resends from a short history, exactly as first sent. Recovery
// works within the Response time; what does not arrive in time plays as silence.
//   NACK packet: "BANK" + SSRC(32) + count(16) + count x seq(16)
#pragma once
#include <array>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <deque>
#include <memory>

#include "common.h"

namespace ba {
constexpr int MaxNack = 64;
constexpr size_t NackHeader = 10;

// Receiver side (packet thread only).
class LossTracker {
   public:
    void received(uint16_t seq);
    // A NACK for every sequence number now due to be asked for; its size, or 0.
    size_t due(uint32_t ssrc, uint8_t *packet);
    uint64_t nacks() const { return nacks_.load(); }
    uint64_t recovered() const { return recovered_.load(); }

   private:
    struct Missing {
        int64_t seq;
        std::chrono::steady_clock::time_point asked;
        int tries;
    };
    int64_t highest_ = -1;
    std::deque<Missing> lost_;
    std::atomic<uint64_t> nacks_{0}, recovered_{0};
};

// Sender side (packet thread only): the last 512 packets, ~2 s at 250/s.
class History {
   public:
    void keep(uint16_t seq, const uint8_t *data, int size);
    // The packet with this sequence number, if still kept.
    bool find(uint16_t seq, const uint8_t *&data, int &size) const;

   private:
    struct Sent {
        uint16_t seq = 0;
        int size = 0;
        uint8_t data[1500];
    };
    std::unique_ptr<std::array<Sent, 512>> sent_{new std::array<Sent, 512>()};
};

// Parses a NACK; seqs points at count big-endian sequence numbers.
bool parse_nack(const uint8_t *packet, int size, uint32_t &ssrc, const uint8_t *&seqs, int &count);
}  // namespace ba
