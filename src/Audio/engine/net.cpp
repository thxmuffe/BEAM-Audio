#include "net.h"

#include <cstring>

namespace ba {
srtp_t make_srtp(uint32_t ssrc, const std::string &key) {
    if (key.size() != SRTP_AES_ICM_128_KEY_LEN_WSALT) fail("SRTP key must be 30 bytes");
    srtp_policy_t policy;
    memset(&policy, 0, sizeof(policy));
    srtp_crypto_policy_set_aes_cm_128_hmac_sha1_80(&policy.rtp);
    srtp_crypto_policy_set_aes_cm_128_hmac_sha1_80(&policy.rtcp);
    policy.ssrc.type = ssrc_specific;
    policy.ssrc.value = ssrc;
    policy.key = reinterpret_cast<uint8_t *>(const_cast<char *>(key.data()));
    policy.window_size = 1024;
    policy.allow_repeat_tx = 1;  // retransmission resends identical packets
    srtp_t session = nullptr;
    if (srtp_create(&session, &policy) != srtp_err_status_ok) fail("srtp_create failed");
    return session;
}

bool parse_rtp(const uint8_t *packet, int size, Rtp &out) {
    if (!rtp_ssrc(packet, size, out.ssrc)) return false;
    int header = RtpHeader + 4 * (packet[0] & 0x0f);
    if (packet[0] & 0x10) {
        if (size < header + 4) return false;
        header += 4 + 4 * (int(packet[header + 2]) << 8 | packet[header + 3]);
    }
    if (packet[0] & 0x20) size -= packet[size - 1];
    if (size <= header) return false;
    out.timestamp = read32(packet + 4);
    out.seq = read16(packet + 2);
    out.payload = packet + header, out.payload_size = size_t(size - header);
    return true;
}

void write_rtp(uint8_t *packet, uint16_t seq, uint32_t timestamp, uint32_t ssrc) {
    packet[0] = 0x80, packet[1] = 96;
    packet[2] = uint8_t(seq >> 8), packet[3] = uint8_t(seq);
    for (int i = 0; i < 4; ++i) packet[4 + i] = uint8_t(timestamp >> (24 - 8 * i)), packet[8 + i] = uint8_t(ssrc >> (24 - 8 * i));
}
}  // namespace ba
