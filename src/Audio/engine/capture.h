// Capture: the one local source (system audio, test tone, later microphone)
// sent as one stream. The shell's callback fills a lock-free ring; the packet
// thread resamples it onto the Session timebase, encodes FLAC blocks and sends
// SRTP packets on the ICE connections Erlang routes it to.
#pragma once
#include <FLAC/stream_encoder.h>
#include <samplerate.h>
#include <srtp2/srtp.h>

#include <array>
#include <atomic>
#include <deque>
#include <memory>
#include <vector>

#include "ice.h"
#include "recovery.h"
#include "timing.h"

namespace ba {
// Single producer (capture callback) / single consumer (packet thread).
struct CaptureRing {
    static constexpr uint32_t Frames = 1u << 16, Records = 512;
    struct Record {
        uint32_t frames;
        uint64_t host;
    };
    std::unique_ptr<float[]> data{new float[Frames * Channels]()};
    std::array<Record, Records> records{};
    std::atomic<uint64_t> frames_written{0}, frames_read{0}, records_written{0}, records_read{0}, overruns{0};
    std::atomic<bool> active{false};

    void push(const float *in, uint32_t frames, uint64_t host);  // real-time safe
    void discard();                                              // consumer: skip what is queued
};

class Sender {
   public:
    // Command map: ssrc, rate, key.
    Sender(const json &command, Ice &ice);
    ~Sender();
    Sender(const Sender &) = delete;
    Sender &operator=(const Sender &) = delete;

    uint32_t ssrc() const { return ssrc_; }
    void set_input_rate(uint32_t rate) { in_rate_.store(rate); }
    uint32_t input_rate() const { return in_rate_.load(); }
    void set_routes(std::vector<ConnId> routes) { routes_ = std::move(routes); }  // packet thread
    // Packet thread: resend the requested packets, exactly as first sent, to
    // the requester, if it is one of this stream's receivers.
    void retransmit(const uint8_t *seqs, int count, ConnId from);
    // Measurements only: drop this share of first transmissions to exercise recovery.
    void set_test_loss(int percent) { test_loss_.store(percent); }
    // Packet thread: encode and send everything the ring holds.
    void drain(CaptureRing &ring, const Clock &clock);
    json status(const CaptureRing &ring);

   private:
    friend FLAC__StreamEncoderWriteStatus sender_write(const FLAC__StreamEncoder *, const FLAC__byte[], size_t, uint32_t, uint32_t,
                                                       void *);
    void append(const float *data, long frames);

    uint32_t ssrc_ = 0, rate_ = 0;
    std::atomic<uint32_t> in_rate_{0};
    Ice &ice_;
    srtp_t srtp_ = nullptr;
    FLAC__StreamEncoder *encoder_ = nullptr;
    SRC_STATE *src_ = nullptr;
    Servo servo_;
    std::vector<ConnId> routes_;  // one ICE connection per receiver
    bool anchored_ = false;
    int64_t anchor_ = 0, out_pos_ = 0;
    // Stream position of the next captured frame fed to the resampler (input x
    // ratio); out_pos_ lags it by whatever the resampler still holds.
    double stream_pos_ = 0;
    std::deque<int64_t> pending_;  // stream position of each block inside the encoder
    std::vector<float> resampled_ = std::vector<float>(size_t(CaptureRing::Frames) * Channels);
    float block_[Block * Channels] = {};
    uint32_t filled_ = 0;
    int64_t block_pos_ = 0;
    uint16_t seq_ = 0;
    History history_;
    std::atomic<int> test_loss_{0};
    std::atomic<uint64_t> sent_{0}, send_errors_{0}, frames_{0}, jumps_{0}, retransmits_{0}, test_dropped_{0};
    ErrorWindow error_;
};
}  // namespace ba
