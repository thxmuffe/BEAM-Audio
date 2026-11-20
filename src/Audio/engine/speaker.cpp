#include "speaker.h"

#include <cstring>
#include <vector>

#include "net.h"

namespace ba {
FLAC__StreamDecoderReadStatus speaker_read(const FLAC__StreamDecoder *, FLAC__byte buffer[], size_t *bytes, void *data) {
    auto &s = *static_cast<Speaker *>(data);
    const size_t left = s.packet_size_ - s.packet_offset_;
    if (!left) {
        *bytes = 0;
        return FLAC__STREAM_DECODER_READ_STATUS_END_OF_STREAM;
    }
    const size_t n = std::min(left, *bytes);
    memcpy(buffer, s.packet_ + s.packet_offset_, n);
    s.packet_offset_ += n;
    *bytes = n;
    return FLAC__STREAM_DECODER_READ_STATUS_CONTINUE;
}

FLAC__StreamDecoderWriteStatus speaker_write(const FLAC__StreamDecoder *, const FLAC__Frame *frame,
                                             const FLAC__int32 *const channels[], void *data) {
    auto &s = *static_cast<Speaker *>(data);
    if (frame->header.blocksize != Block || frame->header.channels != Channels) {
        ++s.rejected_;
        return FLAC__STREAM_DECODER_WRITE_STATUS_CONTINUE;
    }
    // libFLAC first writes silent frames for any gap in frame numbers (its file
    // repair); the packet's own frame comes last. Keep only that one.
    const float scale = 1.0f / float(1u << (frame->header.bits_per_sample - 1));
    for (uint32_t i = 0; i < Block; ++i) {
        s.decoded_frame_[i * 2] = float(channels[0][i]) * scale;
        s.decoded_frame_[i * 2 + 1] = float(channels[1][i]) * scale;
    }
    s.decoded_ = true;
    return FLAC__STREAM_DECODER_WRITE_STATUS_CONTINUE;
}

// A gap in frame numbers is a lost packet, which recovery handles; not an error.
void speaker_error(const FLAC__StreamDecoder *, FLAC__StreamDecoderErrorStatus status, void *data) {
    if (status != FLAC__STREAM_DECODER_ERROR_STATUS_MISSING_FRAME) ++static_cast<Speaker *>(data)->rejected_;
}

namespace {
// Packets carry only FLAC frames; the receiver supplies the matching header.
std::vector<uint8_t> flac_header(uint32_t rate) {
    std::vector<uint8_t> h = {'f', 'L', 'a', 'C', 0x80, 0, 0, 34};
    auto put = [&h](uint64_t v, int bytes) {
        for (int i = bytes - 1; i >= 0; --i) h.push_back(uint8_t(v >> (8 * i)));
    };
    put(Block, 2), put(Block, 2), put(0, 3), put(0, 3);
    put((uint64_t(rate) << 44) | (uint64_t(Channels - 1) << 41) | (uint64_t(Bits - 1) << 36), 8);
    h.insert(h.end(), 16, 0);  // MD5 unknown
    return h;
}
}  // namespace

Speaker::Speaker(const json &c, const Clock &clock) {
    ssrc_ = c.at("ssrc"), rate_ = c.at("rate");
    anchor_ = c.at("anchor_ns").get<int64_t>();
    delay_.store(c.at("delay_ms").get<int64_t>() * 1000000);
    gain_.store(c.value("gain", 1.0f));
    if (rate_ != 44100 && rate_ != 48000) fail("unsupported stream rate");
    for (uint32_t i = 0; i < Blocks; ++i) marks_[i].store(-1);
    srtp_ = make_srtp(ssrc_, c.at("key").get<std::string>());
    int error = 0;
    src_ = src_new(SRC_SINC_MEDIUM_QUALITY, Channels, &error);
    if (!src_) fail("resampler: " + std::string(src_strerror(error)));
    decoder_ = FLAC__stream_decoder_new();
    if (!decoder_ || FLAC__stream_decoder_init_stream(decoder_, speaker_read, nullptr, nullptr, nullptr, nullptr, speaker_write, nullptr,
                                                      speaker_error, this) != FLAC__STREAM_DECODER_INIT_STATUS_OK)
        fail("FLAC decoder init failed");
    const auto header = flac_header(rate_);
    packet_ = header.data(), packet_size_ = header.size(), packet_offset_ = 0;
    if (!FLAC__stream_decoder_process_until_end_of_metadata(decoder_)) fail("FLAC header rejected");
    int64_t now = 0;
    if (!clock.map(host_now_ns(), now)) fail("clock mapping required before start_speaker");
    read_pos_.store(int64_t(std::floor(double(now - anchor_ - delay_.load()) * rate_ / 1e9)));
}

Speaker::~Speaker() {
    if (decoder_) FLAC__stream_decoder_delete(decoder_);
    if (src_) src_delete(src_);
    if (srtp_) srtp_dealloc(srtp_);
}

void Speaker::receive(uint8_t *packet, int size, const sockaddr_in6 &from) {
    const srtp_err_status_t status = srtp_unprotect(srtp_, packet, &size);
    if (status == srtp_err_status_replay_fail || status == srtp_err_status_replay_old) return void(++duplicates_);
    if (status != srtp_err_status_ok) return void(++rejected_);
    Rtp rtp;
    if (!parse_rtp(packet, size, rtp)) return void(++rejected_);
    // Authenticated by SRTP: this is where the stream comes from now (it may
    // change with the sender's network), and its sequence shows what is lost.
    source_ = from, has_source_ = true;
    track(rtp.seq);
    // Extend the 32-bit timestamp to the stream position nearest the reader.
    const int64_t read = read_pos_.load(std::memory_order_acquire);
    const int64_t pos = read + int32_t(rtp.timestamp - uint32_t(read));
    if (pos < 0 || pos % Block) return void(++rejected_);
    if (pos + Block <= read) return void(++late_);
    if (pos >= read + int64_t(RingFrames) - 2 * Block) return void(++early_);
    ++packets_;
    packet_ = rtp.payload, packet_size_ = rtp.payload_size, packet_offset_ = 0;
    block_ = pos / Block, decoded_ = false;
    FLAC__stream_decoder_process_single(decoder_);
    if (decoded_) {
        memcpy(ring_.get() + size_t(block_ % Blocks) * Block * Channels, decoded_frame_, sizeof(decoded_frame_));
        marks_[block_ % Blocks].store(block_ + 1, std::memory_order_release);
    } else {
        ++rejected_;
    }
    if (FLAC__stream_decoder_get_state(decoder_) != FLAC__STREAM_DECODER_SEARCH_FOR_FRAME_SYNC) FLAC__stream_decoder_flush(decoder_);
}

void Speaker::track(uint16_t seq) {
    if (highest_seq_ < 0) return void(highest_seq_ = seq);
    const int64_t ext = highest_seq_ + int16_t(uint16_t(seq - uint16_t(highest_seq_)));
    if (ext > highest_seq_) {
        for (int64_t s = std::max(highest_seq_ + 1, ext - 64); s < ext; ++s) lost_.push_back({s, {}, 0});
        highest_seq_ = ext;
        while (lost_.size() > 256) lost_.pop_front();
    } else {
        for (auto it = lost_.begin(); it != lost_.end(); ++it)
            if (it->seq == ext) {
                lost_.erase(it);
                ++recovered_;
                break;
            }
    }
}

void Speaker::send_nacks(int socket) {
    if (!has_source_ || lost_.empty()) return;
    const auto now = std::chrono::steady_clock::now();
    uint8_t packet[10 + 2 * 64];
    memcpy(packet, "BANK", 4);
    for (int i = 0; i < 4; ++i) packet[4 + i] = uint8_t(ssrc_ >> (24 - 8 * i));
    uint16_t count = 0;
    for (auto it = lost_.begin(); it != lost_.end() && count < 64;) {
        if (it->tries >= 3) {
            it = lost_.erase(it);
            continue;
        }
        if (it->tries == 0 || now - it->asked >= std::chrono::milliseconds(30)) {
            packet[10 + 2 * count] = uint8_t(it->seq >> 8), packet[11 + 2 * count] = uint8_t(it->seq);
            ++count, ++it->tries, it->asked = now;
        }
        ++it;
    }
    if (!count) return;
    packet[8] = uint8_t(count >> 8), packet[9] = uint8_t(count);
    sendto(socket, packet, 10 + 2 * size_t(count), 0, reinterpret_cast<const sockaddr *>(&source_), sizeof(source_));
    ++nacks_;
}

// Copies frames [pos, pos + n) from the ring; absent blocks play as silence.
void Speaker::read_ring(int64_t pos, long n, float *dest) {
    long done = 0;
    while (done < n) {
        const int64_t p = pos + done;
        const int64_t block = p >= 0 ? p / Block : (p - Block + 1) / Block;
        const long offset = long(p - block * Block), take = std::min<long>(n - done, Block - offset);
        if (block >= 0 && marks_[block % Blocks].load(std::memory_order_acquire) == block + 1) {
            memcpy(dest + done * Channels, ring_.get() + (size_t(block % Blocks) * Block + offset) * Channels,
                   size_t(take) * Channels * sizeof(float));
        } else {
            memset(dest + done * Channels, 0, size_t(take) * Channels * sizeof(float));
            if (block >= 0) missing_.fetch_add(uint64_t(take), std::memory_order_relaxed);
        }
        done += take;
    }
}

void Speaker::render(float *mix, uint32_t frames, int64_t present, uint32_t out_rate) {
    // Stream sample n plays at anchor + delay + n / rate.
    const double desired = double(present - anchor_ - delay_.load(std::memory_order_relaxed)) * rate_ / 1e9;
    const double base = double(out_rate) / double(rate_);
    double error = play_pos_ - desired;
    if (!started_ || std::fabs(error) > JumpSeconds * rate_) {
        if (started_) jumps_.fetch_add(1, std::memory_order_relaxed);
        chunk_start_ = int64_t(std::floor(desired)), chunk_size_ = chunk_used_ = 0;
        play_pos_ = double(chunk_start_);
        src_reset(src_);
        servo_.reset();
        last_ratio_ = 0;
        started_ = true;
        error = play_pos_ - desired;
    }
    error_.add(int64_t(error * 1e9 / rate_));
    // Ahead (error > 0): consume the stream more slowly, so raise the ratio.
    const double ratio = base * (1.0 + servo_.correction(error));
    // libsamplerate moves linearly from the previous ratio to the new one.
    const double applied = last_ratio_ > 0 ? (last_ratio_ + ratio) / 2 : ratio;
    last_ratio_ = ratio;
    float *out = out_.get();
    long produced = 0;
    while (produced < long(frames)) {
        if (chunk_used_ == chunk_size_) {
            chunk_start_ += chunk_size_;
            read_ring(chunk_start_, Chunk, chunk_);
            chunk_size_ = Chunk, chunk_used_ = 0;
        }
        SRC_DATA d{};
        d.data_in = chunk_ + chunk_used_ * Channels;
        d.input_frames = chunk_size_ - chunk_used_;
        d.data_out = out + produced * Channels;
        d.output_frames = long(frames) - produced;
        d.src_ratio = ratio;
        if (src_process(src_, &d) || (!d.input_frames_used && !d.output_frames_gen)) break;
        chunk_used_ += d.input_frames_used;
        produced += d.output_frames_gen;
    }
    play_pos_ += double(produced) / applied;
    const float gain = gain_.load(std::memory_order_relaxed);
    for (long i = 0; i < produced * long(Channels); ++i) mix[i] += out[i] * gain;
    read_pos_.store(chunk_start_ + chunk_used_, std::memory_order_release);
}

json Speaker::status() {
    return {{"ssrc", ssrc_},       {"packets", packets_.load()}, {"duplicates", duplicates_.load()},        {"late", late_.load()},
            {"early", early_.load()}, {"rejected", rejected_.load()},      {"missing_frames", missing_.load()},
            {"jumps", jumps_.load()}, {"nacks", nacks_.load()}, {"recovered", recovered_.load()},
            {"error", error_.take()}};
}
}  // namespace ba
