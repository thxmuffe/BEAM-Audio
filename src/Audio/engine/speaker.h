// Speaker: one received stream. The packet thread decodes FLAC frames into a
// ring indexed by stream sample position; the render callback reads the ring
// by Session time and resamples it onto the output device.
#pragma once
#include <FLAC/stream_decoder.h>
#include <samplerate.h>
#include <srtp2/srtp.h>

#include <atomic>
#include <memory>

#include "timing.h"

namespace ba {
constexpr uint32_t Blocks = 1024;
constexpr uint32_t RingFrames = Block * Blocks;  // ~4 s at 48 kHz
constexpr uint32_t MaxCallback = 8192;           // largest device callback served
constexpr uint32_t Chunk = 32;                   // frames handed to the resampler at a time

class Speaker {
   public:
    // Command map: ssrc, rate, anchor_ns, delay_ms, key, gain (optional).
    Speaker(const json &command, const Clock &clock);
    ~Speaker();
    Speaker(const Speaker &) = delete;
    Speaker &operator=(const Speaker &) = delete;

    uint32_t ssrc() const { return ssrc_; }
    // Packet thread: an SRTP packet for this SSRC (decrypted in place).
    void receive(uint8_t *packet, int size);
    // Audio thread: add this stream's frames for Session time `present` to mix.
    void render(float *mix, uint32_t frames, int64_t present, uint32_t out_rate);
    json status();
    void set_gain(float gain) { gain_.store(gain, std::memory_order_relaxed); }

   private:
    friend FLAC__StreamDecoderReadStatus speaker_read(const FLAC__StreamDecoder *, FLAC__byte[], size_t *, void *);
    friend FLAC__StreamDecoderWriteStatus speaker_write(const FLAC__StreamDecoder *, const FLAC__Frame *, const FLAC__int32 *const[],
                                                        void *);
    friend void speaker_error(const FLAC__StreamDecoder *, FLAC__StreamDecoderErrorStatus, void *);
    void read_ring(int64_t pos, long frames, float *dest);

    uint32_t ssrc_ = 0, rate_ = 0;
    int64_t anchor_ = 0, delay_ = 0;
    std::atomic<float> gain_{1};
    srtp_t srtp_ = nullptr;
    FLAC__StreamDecoder *decoder_ = nullptr;
    // Packet being decoded (packet thread only).
    const uint8_t *packet_ = nullptr;
    size_t packet_size_ = 0, packet_offset_ = 0;
    int64_t block_ = 0;
    bool decoded_ = false;
    std::unique_ptr<float[]> ring_{new float[RingFrames * Channels]()};
    std::unique_ptr<std::atomic<int64_t>[]> marks_{new std::atomic<int64_t>[Blocks]};
    std::atomic<int64_t> read_pos_{0};  // published by render, bounds writes
    // Render state (audio thread only).
    SRC_STATE *src_ = nullptr;
    bool started_ = false;
    Servo servo_;
    float chunk_[Chunk * Channels] = {};
    int64_t chunk_start_ = 0;
    // Stream position of the next output frame. libsamplerate takes input ahead
    // of its output by a varying amount, so position follows output / ratio.
    double play_pos_ = 0, last_ratio_ = 0;
    long chunk_size_ = 0, chunk_used_ = 0;
    std::unique_ptr<float[]> out_{new float[MaxCallback * Channels]()};
    // Counters.
    // duplicates: the same packet again (sent to several of our addresses, or resent).
    std::atomic<uint64_t> packets_{0}, duplicates_{0}, late_{0}, early_{0}, rejected_{0}, missing_{0}, jumps_{0};
    ErrorWindow error_;
};
}  // namespace ba
