#include "speaker.h"

#include <algorithm>
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

Speaker::Speaker(const json &c, const Clock &clock) : clock_(clock) {
    ssrc_ = c.at("ssrc"), rate_ = c.at("rate");
    anchor_ = c.at("anchor_ns").get<int64_t>();
    delay_.store(c.at("delay_ms").get<int64_t>() * 1000000);
    gain_.store(c.value("gain", 1.0f));
    if (rate_ != 44100 && rate_ != 48000) fail("unsupported stream rate");
    for (uint32_t i = 0; i < Blocks; ++i) marks_[i].store(-1);
    srtp_ = make_srtp(ssrc_, c.at("key").get<std::string>());
    initial_index_ = c.at("packet_index").get<uint64_t>();
    if (initial_index_ >= (uint64_t(1) << 48)) fail("invalid SRTP packet index");
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

void Speaker::receive(uint8_t *packet, int size, ConnId from) {
    if (!authenticated_ && !prime_srtp(srtp_, ssrc_, initial_index_, read16(packet + 2))) return void(++rejected_);
    const srtp_err_status_t status = srtp_unprotect(srtp_, packet, &size);
    if (status == srtp_err_status_replay_fail || status == srtp_err_status_replay_old) return void(++duplicates_);
    if (status != srtp_err_status_ok) return void(++rejected_);
    authenticated_ = true;
    Rtp rtp;
    if (!parse_rtp(packet, size, rtp)) return void(++rejected_);
    // Authenticated by SRTP: this is where the stream comes from now (it may
    // change with the sender's network), and its sequence shows what is lost.
    source_ = from, has_source_ = true;
    loss_.received(rtp.seq);
    // Extend the 32-bit timestamp to the stream position nearest the reader.
    const int64_t read = read_pos_.load(std::memory_order_acquire);
    const int64_t pos = read + int32_t(rtp.timestamp - uint32_t(read));
    if (pos < 0 || pos % Block) return void(++rejected_);
    // The Response time this packet needed, late or not: its last sample was
    // captured at anchor + (pos + Block) / rate.
    if (int64_t now = 0; clock_.map(host_now_ns(), now)) {
        const int64_t need = now - anchor_ - (pos + Block) * int64_t(1000000000) / rate_ + render_lead_ns_.load(std::memory_order_relaxed);
        response_[std::clamp<int64_t>(need / 1000000, 0, ResponseBins - 1)].fetch_add(1, std::memory_order_relaxed);
        response_sum_ns_.fetch_add(std::max<int64_t>(need, 0), std::memory_order_relaxed);
    }
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

void Speaker::send_nacks(Ice &ice) {
    uint8_t packet[NackHeader + 2 * MaxNack];
    if (const size_t size = has_source_ ? loss_.due(ssrc_, packet) : 0) ice.send(source_, packet, size);
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
    if (int64_t now = 0; clock_.map(host_now_ns(), now)) render_lead_ns_.store(present - now, std::memory_order_relaxed);
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

json Speaker::take_response() {
    uint64_t count = 0;
    int max = -1;
    std::vector<uint32_t> bins(ResponseBins);
    for (int i = 0; i < ResponseBins; ++i)
        if ((bins[size_t(i)] = response_[i].exchange(0, std::memory_order_relaxed))) count += bins[size_t(i)], max = i;
    const int64_t sum = response_sum_ns_.exchange(0, std::memory_order_relaxed);
    json out = {{"ssrc", ssrc_}, {"count", count}};
    if (!count) return out;
    // The smallest Response time that would have played this share of packets in time.
    const auto percentile = [&](uint64_t share) {
        uint64_t seen = 0;
        for (int i = 0; i < ResponseBins; ++i)
            if ((seen += bins[size_t(i)]) * 100 >= count * share) return i + 1;
        return ResponseBins;
    };
    out["mean_ms"] = int64_t(sum / int64_t(count) / 1000000 + 1), out["p85_ms"] = percentile(85), out["p99_ms"] = percentile(99),
    out["max_ms"] = max + 1;
    return out;
}

json Speaker::status() {
    return {{"ssrc", ssrc_},       {"packets", packets_.load()}, {"duplicates", duplicates_.load()},        {"late", late_.load()},
            {"early", early_.load()}, {"rejected", rejected_.load()},      {"missing_frames", missing_.load()},
            {"jumps", jumps_.load()}, {"nacks", loss_.nacks()}, {"recovered", loss_.recovered()},
            {"error", error_.take()}};
}
}  // namespace ba
