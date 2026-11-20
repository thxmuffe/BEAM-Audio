// Capture: the one local source (system audio, test tone, later microphone)
// sent as one stream. The shell's callback fills a lock-free ring; the packet
// thread resamples it onto the Session timebase, encodes FLAC blocks and sends
// SRTP packets to the peers Erlang named.
#pragma once
#include <FLAC/stream_encoder.h>
#include <netinet/in.h>
#include <samplerate.h>
#include <srtp2/srtp.h>

#include <array>
#include <atomic>
#include <deque>
#include <memory>
#include <vector>

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
    // Command map: ssrc, rate, key, peers.
    Sender(const json &command, int socket);
    ~Sender();
    Sender(const Sender &) = delete;
    Sender &operator=(const Sender &) = delete;

    uint32_t ssrc() const { return ssrc_; }
    void set_input_rate(uint32_t rate) { in_rate_.store(rate); }
    uint32_t input_rate() const { return in_rate_.load(); }
    void set_peers(std::vector<sockaddr_in6> peers) { peers_ = std::move(peers); }  // packet thread
    // Packet thread: encode and send everything the ring holds.
    void drain(CaptureRing &ring, const Clock &clock);
    json status(const CaptureRing &ring);

   private:
    friend FLAC__StreamEncoderWriteStatus sender_write(const FLAC__StreamEncoder *, const FLAC__byte[], size_t, uint32_t, uint32_t,
                                                       void *);
    void append(const float *data, long frames);

    uint32_t ssrc_ = 0, rate_ = 0;
    std::atomic<uint32_t> in_rate_{0};
    int socket_ = -1;
    srtp_t srtp_ = nullptr;
    FLAC__StreamEncoder *encoder_ = nullptr;
    SRC_STATE *src_ = nullptr;
    Servo servo_;
    std::vector<sockaddr_in6> peers_;
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
    std::atomic<uint64_t> sent_{0}, send_errors_{0}, frames_{0}, jumps_{0};
    ErrorWindow error_;
};
}  // namespace ba
