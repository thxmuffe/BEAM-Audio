#include "net.h"

#include <arpa/inet.h>
#include <fcntl.h>
#include <netdb.h>
#include <sys/socket.h>
#include <unistd.h>

#include <cstring>

namespace ba {
int open_socket(uint16_t wanted, uint16_t &port) {
    const int fd = ::socket(AF_INET6, SOCK_DGRAM, 0);
    if (fd < 0) fail("socket failed");
    int no = 0, size = 4 << 20;
    setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &no, sizeof(no));
    setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &size, sizeof(size));
    setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &size, sizeof(size));
    sockaddr_in6 a{};
    a.sin6_family = AF_INET6, a.sin6_addr = in6addr_any, a.sin6_port = htons(wanted);
    if (bind(fd, reinterpret_cast<sockaddr *>(&a), sizeof(a))) {
        close(fd);
        fail("bind failed on port " + std::to_string(wanted));
    }
    fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);
    socklen_t len = sizeof(a);
    getsockname(fd, reinterpret_cast<sockaddr *>(&a), &len);
    port = ntohs(a.sin6_port);
    return fd;
}

std::vector<sockaddr_in6> parse_peers(const json &list) {
    std::vector<sockaddr_in6> peers;
    for (const auto &p : list) {
        const std::string host = p.at(0);
        const uint16_t port = p.at(1);
        addrinfo hints{}, *found = nullptr;
        hints.ai_family = AF_INET6, hints.ai_flags = AI_NUMERICHOST | AI_V4MAPPED, hints.ai_socktype = SOCK_DGRAM;
        if (getaddrinfo(host.c_str(), nullptr, &hints, &found) || !found) fail("invalid peer address " + host);
        sockaddr_in6 a = *reinterpret_cast<sockaddr_in6 *>(found->ai_addr);
        freeaddrinfo(found);
        a.sin6_port = htons(port);
        peers.push_back(a);
    }
    return peers;
}

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

bool same_peer(const sockaddr_in6 &a, const sockaddr_in6 &b) {
    return a.sin6_port == b.sin6_port && !memcmp(&a.sin6_addr, &b.sin6_addr, sizeof(a.sin6_addr));
}

std::string host_of(const sockaddr_in6 &a) {
    char text[INET6_ADDRSTRLEN] = {};
    if (IN6_IS_ADDR_V4MAPPED(&a.sin6_addr)) inet_ntop(AF_INET, &a.sin6_addr.s6_addr[12], text, sizeof(text));
    else inet_ntop(AF_INET6, &a.sin6_addr, text, sizeof(text));
    return text;
}

constexpr uint32_t StunCookie = 0x2112A442;

void write_stun_request(uint8_t *packet, const std::string &transaction) {
    packet[0] = 0x00, packet[1] = 0x01, packet[2] = 0x00, packet[3] = 0x00;  // Binding request, no attributes
    for (int i = 0; i < 4; ++i) packet[4 + i] = uint8_t(StunCookie >> (24 - 8 * i));
    memcpy(packet + 8, transaction.data(), 12);
}

bool parse_stun_response(const uint8_t *packet, int size, std::string &transaction, sockaddr_in6 &mapped) {
    if (size < StunHeader || read16(packet) != 0x0101 || read32(packet + 4) != StunCookie) return false;
    const int length = read16(packet + 2);
    if (StunHeader + length > size) return false;
    transaction.assign(reinterpret_cast<const char *>(packet + 8), 12);
    for (int at = StunHeader; at + 4 <= StunHeader + length;) {
        const int type = read16(packet + at), len = read16(packet + at + 2);
        const uint8_t *value = packet + at + 4;
        if (at + 4 + len > size) return false;
        if (type == 0x0020 && len >= 8) {  // XOR-MAPPED-ADDRESS
            mapped = sockaddr_in6{};
            mapped.sin6_family = AF_INET6;
            mapped.sin6_port = htons(uint16_t(read16(value + 2) ^ (StunCookie >> 16)));
            if (value[1] == 0x01) {  // IPv4, as an IPv4-mapped address for the dual-stack socket
                mapped.sin6_addr.s6_addr[10] = mapped.sin6_addr.s6_addr[11] = 0xff;
                for (int i = 0; i < 4; ++i) mapped.sin6_addr.s6_addr[12 + i] = value[4 + i] ^ packet[4 + i];
                return true;
            }
            if (value[1] == 0x02 && len >= 20) {  // IPv6: XOR with cookie and transaction ID
                for (int i = 0; i < 16; ++i) mapped.sin6_addr.s6_addr[i] = value[4 + i] ^ packet[4 + i];
                return true;
            }
        }
        at += 4 + ((len + 3) & ~3);
    }
    return false;
}

void write_rtp(uint8_t *packet, uint16_t seq, uint32_t timestamp, uint32_t ssrc) {
    packet[0] = 0x80, packet[1] = 96;
    packet[2] = uint8_t(seq >> 8), packet[3] = uint8_t(seq);
    for (int i = 0; i < 4; ++i) packet[4 + i] = uint8_t(timestamp >> (24 - 8 * i)), packet[8 + i] = uint8_t(ssrc >> (24 - 8 * i));
}
}  // namespace ba
