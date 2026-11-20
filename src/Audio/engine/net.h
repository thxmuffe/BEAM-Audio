// Network: one dual-stack UDP socket, peer addresses, SRTP sessions, RTP headers.
#pragma once
#include <netinet/in.h>
#include <srtp2/srtp.h>

#include <cstdint>
#include <cstring>
#include <string>
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
    uint16_t seq = 0;
    const uint8_t *payload = nullptr;
    size_t payload_size = 0;
};
inline uint16_t read16(const uint8_t *p) { return uint16_t(p[0] << 8 | p[1]); }
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

// Control packets between engines. RTP starts with version 2 (0x80..0xBF), so
// an ASCII tag never collides with media.
//   probe  "BAPR" + 16-byte token: Erlang's connectivity check; echoed back
//   answer "BAPA" + the same token: proves the path both ways
//   nack   "BANK" + SSRC + count(16) + count x seq(16): resend these packets
constexpr int ProbeSize = 20;

// STUN (RFC 5389) Binding: what address the internet sees for our socket.
// The 12-byte transaction ID is Erlang's token. STUN's first two bits are 00,
// so it never collides with RTP (10) or the ASCII tags above.
constexpr int StunHeader = 20;
void write_stun_request(uint8_t *packet, const std::string &transaction);
// A Binding success response: its transaction ID and XOR-MAPPED-ADDRESS.
bool parse_stun_response(const uint8_t *packet, int size, std::string &transaction, sockaddr_in6 &mapped);
inline bool tagged(const uint8_t *p, int size, const char *tag) { return size >= 4 && !memcmp(p, tag, 4); }
bool same_peer(const sockaddr_in6 &a, const sockaddr_in6 &b);
// Printable address; IPv4-mapped addresses print as plain IPv4.
std::string host_of(const sockaddr_in6 &a);
}  // namespace ba
