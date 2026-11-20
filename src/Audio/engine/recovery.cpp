#include "recovery.h"

#include <cstring>

#include "net.h"

namespace ba {
void LossTracker::received(uint16_t seq) {
    if (highest_ < 0) return void(highest_ = seq);
    const int64_t ext = highest_ + int16_t(uint16_t(seq - uint16_t(highest_)));
    if (ext > highest_) {
        for (int64_t s = std::max(highest_ + 1, ext - MaxNack); s < ext; ++s) lost_.push_back({s, {}, 0});
        highest_ = ext;
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

size_t LossTracker::due(uint32_t ssrc, uint8_t *packet) {
    if (lost_.empty()) return 0;
    const auto now = std::chrono::steady_clock::now();
    memcpy(packet, "BANK", 4);
    for (int i = 0; i < 4; ++i) packet[4 + i] = uint8_t(ssrc >> (24 - 8 * i));
    uint16_t count = 0;
    for (auto it = lost_.begin(); it != lost_.end() && count < MaxNack;) {
        if (it->tries >= 3) {
            it = lost_.erase(it);
            continue;
        }
        if (it->tries == 0 || now - it->asked >= std::chrono::milliseconds(30)) {
            packet[NackHeader + 2 * count] = uint8_t(it->seq >> 8), packet[NackHeader + 1 + 2 * count] = uint8_t(it->seq);
            ++count, ++it->tries, it->asked = now;
        }
        ++it;
    }
    if (!count) return 0;
    packet[8] = uint8_t(count >> 8), packet[9] = uint8_t(count);
    ++nacks_;
    return NackHeader + 2 * size_t(count);
}

void History::keep(uint16_t seq, const uint8_t *data, int size) {
    auto &kept = (*sent_)[seq % sent_->size()];
    kept.seq = seq, kept.size = size;
    memcpy(kept.data, data, size_t(size));
}

bool History::find(uint16_t seq, const uint8_t *&data, int &size) const {
    const auto &kept = (*sent_)[seq % sent_->size()];
    if (!kept.size || kept.seq != seq) return false;
    data = kept.data, size = kept.size;
    return true;
}

bool parse_nack(const uint8_t *packet, int size, uint32_t &ssrc, const uint8_t *&seqs, int &count) {
    if (size < int(NackHeader) || memcmp(packet, "BANK", 4)) return false;
    ssrc = read32(packet + 4), count = read16(packet + 8), seqs = packet + NackHeader;
    return count <= MaxNack && size >= int(NackHeader) + 2 * count;
}
}  // namespace ba
