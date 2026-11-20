// Network: one dual-stack UDP socket, peer addresses, SRTP sessions, RTP headers.
#pragma once
#include <netinet/in.h>
#include <srtp2/srtp.h>

#include <cstdint>
#include <vector>

#include "common.h"

namespace ba {
// Binds a non-blocking dual-stack UDP socket; port 0 picks one. Returns fd, sets port.
int open_socket(uint16_t wanted, uint16_t &port);
// [["192.168.1.5", 40000], ["::1", 40001]] -> addresses for the dual-stack socket.
std::vector<sockaddr_in6> parse_peers(const json &list);
// AES-CM-128 / HMAC-SHA1-80 for one SSRC; key is the 30-byte master key+salt.
srtp_t make_srtp(uint32_t ssrc, const std::string &key);

constexpr int RtpHeader = 12;
struct Rtp {
    uint32_t ssrc = 0, timestamp = 0;
    const uint8_t *payload = nullptr;
    size_t payload_size = 0;
};
inline uint32_t read32(const uint8_t *p) { return uint32_t(p[0]) << 24 | uint32_t(p[1]) << 16 | uint32_t(p[2]) << 8 | p[3]; }
// SSRC of an RTP packet before decryption (the header is not encrypted).
inline bool rtp_ssrc(const uint8_t *packet, int size, uint32_t &ssrc) {
    if (size < RtpHeader || (packet[0] >> 6) != 2) return false;
    ssrc = read32(packet + 8);
    return true;
}
// Parses a decrypted RTP packet: CSRCs, extension and padding are skipped.
bool parse_rtp(const uint8_t *packet, int size, Rtp &out);
// Writes a 12-byte header (version 2, payload type 96).
void write_rtp(uint8_t *packet, uint16_t seq, uint32_t timestamp, uint32_t ssrc);
}  // namespace ba
