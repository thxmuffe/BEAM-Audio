#include "capture.h"


#include <cstdlib>
#include <cstring>

#include "net.h"

namespace ba {
void CaptureRing::push(const float *in, uint32_t n, uint64_t host) {
    const uint64_t fw = frames_written.load(std::memory_order_relaxed), rw = records_written.load(std::memory_order_relaxed);
    if (fw + n - frames_read.load(std::memory_order_acquire) > Frames || rw - records_read.load(std::memory_order_acquire) >= Records) {
        overruns.fetch_add(1, std::memory_order_relaxed);
        return;
    }
    for (uint32_t i = 0; i < n; ++i) {
        const size_t at = size_t((fw + i) % Frames) * Channels;
        data[at] = in[i * 2], data[at + 1] = in[i * 2 + 1];
    }
    records[rw % Records] = {n, host};
    frames_written.store(fw + n, std::memory_order_release);
    records_written.store(rw + 1, std::memory_order_release);
}

void CaptureRing::discard() {
    frames_read.store(frames_written.load(std::memory_order_acquire), std::memory_order_release);
    records_read.store(records_written.load(std::memory_order_acquire), std::memory_order_release);
}

FLAC__StreamEncoderWriteStatus sender_write(const FLAC__StreamEncoder *, const FLAC__byte buffer[], size_t bytes, uint32_t samples,
                                            uint32_t, void *data) {
    auto &s = *static_cast<Sender *>(data);
    if (!samples) return FLAC__STREAM_ENCODER_WRITE_STATUS_OK;  // stream header: receivers build their own
    if (s.pending_.empty()) return ++s.send_errors_, FLAC__STREAM_ENCODER_WRITE_STATUS_OK;
    const uint32_t timestamp = uint32_t(s.pending_.front());
    s.pending_.pop_front();
    uint8_t packet[1500];
    if (bytes + RtpHeader + SRTP_MAX_TRAILER_LEN > sizeof(packet)) return ++s.send_errors_, FLAC__STREAM_ENCODER_WRITE_STATUS_OK;
    const uint16_t seq = uint16_t(s.next_index_.fetch_add(1, std::memory_order_relaxed));
    write_rtp(packet, seq, timestamp, s.ssrc_);
    memcpy(packet + RtpHeader, buffer, bytes);
    int size = int(RtpHeader + bytes);
    if (srtp_protect(s.srtp_, packet, &size) != srtp_err_status_ok) return ++s.send_errors_, FLAC__STREAM_ENCODER_WRITE_STATUS_OK;
    s.history_.keep(seq, packet, size);
    if (s.test_loss_.load() > 0 && std::rand() % 100 < s.test_loss_.load()) return ++s.test_dropped_, FLAC__STREAM_ENCODER_WRITE_STATUS_OK;
    for (ConnId route : s.routes_)
        if (s.ice_.send(route, packet, size_t(size)))
            ++s.sent_;
        else
            ++s.send_errors_;
    return FLAC__STREAM_ENCODER_WRITE_STATUS_OK;
}

void Sender::retransmit(const uint8_t *seqs, int count, ConnId from) {
    if (std::find(routes_.begin(), routes_.end(), from) == routes_.end()) return;  // only to this stream's receivers
    for (int i = 0; i < count; ++i) {
        const uint8_t *data = nullptr;
        int size = 0;
        if (history_.find(read16(seqs + 2 * i), data, size) && ice_.send(from, data, size_t(size))) ++retransmits_;
    }
}

Sender::Sender(const json &c, Ice &ice) : ice_(ice) {
    ssrc_ = c.at("ssrc"), rate_ = c.at("rate");
    if (rate_ != 44100 && rate_ != 48000) fail("unsupported stream rate");
    srtp_ = make_srtp(ssrc_, c.at("key").get<std::string>());
    int error = 0;
    src_ = src_new(SRC_SINC_MEDIUM_QUALITY, Channels, &error);
    if (!src_) fail("resampler: " + std::string(src_strerror(error)));
    encoder_ = FLAC__stream_encoder_new();
    if (!encoder_) fail("FLAC encoder allocation failed");
    FLAC__stream_encoder_set_channels(encoder_, Channels);
    FLAC__stream_encoder_set_bits_per_sample(encoder_, Bits);
    FLAC__stream_encoder_set_sample_rate(encoder_, rate_);
    FLAC__stream_encoder_set_blocksize(encoder_, Block);
    FLAC__stream_encoder_set_compression_level(encoder_, 2);
    FLAC__stream_encoder_set_streamable_subset(encoder_, true);
    if (FLAC__stream_encoder_init_stream(encoder_, sender_write, nullptr, nullptr, nullptr, this) != FLAC__STREAM_ENCODER_INIT_STATUS_OK)
        fail("FLAC encoder init failed");
}

Sender::~Sender() {
    if (encoder_) FLAC__stream_encoder_delete(encoder_);
    if (src_) src_delete(src_);
    if (srtp_) srtp_dealloc(srtp_);
}

void Sender::drain(CaptureRing &ring, const Clock &clock) {
    const uint32_t in_rate = in_rate_.load();
    if (!in_rate) return ring.discard();
    while (ring.records_read.load() < ring.records_written.load(std::memory_order_acquire)) {
        const auto record = ring.records[ring.records_read.load() % CaptureRing::Records];
        const uint64_t first = ring.frames_read.load();
        int64_t session = 0;
        if (!clock.map(record.host, session)) fail("capture before clock mapping");
        if (!anchored_) {
            // Stream sample 0 is the first captured frame, at this Session time.
            anchored_ = true, anchor_ = session;
            emit({{"event", "capture_started"}, {"ssrc", ssrc_}, {"anchor_ns", anchor_}, {"rate", rate_}});
        }
        const double desired = double(session - anchor_) * rate_ / 1e9;
        double error = stream_pos_ - desired;
        if (std::fabs(error) > JumpSeconds * rate_) {
            // Renumber from the Session timeline; receivers hear a gap or overlap.
            ++jumps_;
            out_pos_ = int64_t(std::llround(desired / Block)) * Block;
            stream_pos_ = double(out_pos_);
            filled_ = 0, block_pos_ = out_pos_;
            src_reset(src_), servo_.reset();
            error = stream_pos_ - desired;
        }
        error_.add(int64_t(error * 1e9 / rate_));
        // Ahead (error > 0): produce fewer stream samples, so lower the ratio.
        const double ratio = double(rate_) / in_rate * (1.0 - servo_.correction(error));
        float input[4096 * Channels];
        uint32_t left = record.frames;
        uint64_t at = first;
        while (left) {
            const uint32_t n = std::min<uint32_t>(left, 4096);
            for (uint32_t i = 0; i < n; ++i) {
                const size_t from = size_t((at + i) % CaptureRing::Frames) * Channels;
                input[i * 2] = ring.data[from], input[i * 2 + 1] = ring.data[from + 1];
            }
            long used = 0;
            while (used < long(n)) {
                SRC_DATA d{};
                d.data_in = input + used * Channels;
                d.input_frames = long(n) - used;
                d.data_out = resampled_.data();
                d.output_frames = long(resampled_.size() / Channels);
                d.src_ratio = ratio;
                if (src_process(src_, &d)) fail("resampler failed");
                used += d.input_frames_used;
                append(resampled_.data(), d.output_frames_gen);
                if (!d.input_frames_used && !d.output_frames_gen) break;
            }
            at += n, left -= n;
        }
        stream_pos_ += double(record.frames) * ratio;
        frames_ += record.frames;
        ring.frames_read.store(first + record.frames, std::memory_order_release);
        ring.records_read.fetch_add(1, std::memory_order_release);
    }
}

// Collects resampled frames into fixed blocks; each block becomes one packet.
void Sender::append(const float *data, long frames) {
    for (long i = 0; i < frames; ++i) {
        if (!filled_) block_pos_ = out_pos_;
        block_[filled_ * 2] = data[i * 2], block_[filled_ * 2 + 1] = data[i * 2 + 1];
        ++out_pos_;
        if (++filled_ == Block) {
            FLAC__int32 pcm[Block * Channels];
            const float full = float((1 << (Bits - 1)) - 1);
            for (uint32_t k = 0; k < Block * Channels; ++k) pcm[k] = FLAC__int32(std::lrint(std::clamp(block_[k], -1.0f, 1.0f) * full));
            pending_.push_back(block_pos_);
            if (!FLAC__stream_encoder_process_interleaved(encoder_, pcm, Block)) fail("FLAC encoder failed");
            filled_ = 0;
        }
    }
}

json Sender::status(const CaptureRing &ring) {
    return {{"ssrc", ssrc_},           {"frames", frames_.load()},        {"sent", sent_.load()},     {"send_errors", send_errors_.load()},
            {"overruns", ring.overruns.load()}, {"jumps", jumps_.load()},
            {"retransmits", retransmits_.load()}, {"test_dropped", test_dropped_.load()}, {"error", error_.take()}};
}
}  // namespace ba
