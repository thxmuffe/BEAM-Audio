#include "net.h"

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
    out.payload = packet + header, out.payload_size = size_t(size - header);
    return true;
}

void write_rtp(uint8_t *packet, uint16_t seq, uint32_t timestamp, uint32_t ssrc) {
    packet[0] = 0x80, packet[1] = 96;
    packet[2] = uint8_t(seq >> 8), packet[3] = uint8_t(seq);
    for (int i = 0; i < 4; ++i) packet[4 + i] = uint8_t(timestamp >> (24 - 8 * i)), packet[8 + i] = uint8_t(ssrc >> (24 - 8 * i));
}
}  // namespace ba
