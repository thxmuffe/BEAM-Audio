// No audio devices or network: exercise the engine's real SRTP construction
// and initial-index handoff against the pinned libsrtp implementation.
#include "net.h"

#include <array>
#include <cstring>
#include <iostream>
#include <stdexcept>
#include <vector>

namespace {
constexpr uint32_t Ssrc = 12345;
const std::string Key(30, 'x');  // test material only
struct Packet {
    uint64_t index;
    std::array<uint8_t, 128> bytes;
    int size;
};
void check(bool condition, const char *message) {
    if (!condition) throw std::runtime_error(message);
}
srtp_err_status_t receive(srtp_t receiver, const Packet &p) {
    auto bytes = p.bytes;
    int size = p.size;
    return srtp_unprotect(receiver, bytes.data(), &size);
}
void rejoin(const Packet &p, uint64_t reference) {
    auto receiver = ba::make_srtp(Ssrc, Key);
    check(ba::prime_srtp(receiver, Ssrc, reference, ba::read16(p.bytes.data() + 2)), "could not prime SRTP");
    check(receive(receiver, p) == srtp_err_status_ok, "rejoined packet did not authenticate");
    const auto replay = receive(receiver, p);
    check(replay == srtp_err_status_replay_fail || replay == srtp_err_status_replay_old, "replay was accepted");
    srtp_dealloc(receiver);
}
}  // namespace

int main() {
    try {
        check(srtp_init() == srtp_err_status_ok, "SRTP init failed");
        auto sender = ba::make_srtp(Ssrc, Key);
        std::vector<Packet> saved;
        for (uint32_t i = 0; i <= 196615; ++i) {
            Packet p{i, {}, 16};
            ba::write_rtp(p.bytes.data(), uint16_t(i), i * 192, Ssrc);
            std::memcpy(p.bytes.data() + 12, "test", 4);
            check(srtp_protect(sender, p.bytes.data(), &p.size) == srtp_err_status_ok, "protect failed");
            if (i == 0 || i == 60000 || i == 65535 || i == 65536 || i == 131072 || i == 196615) saved.push_back(p);
        }
        auto unseeded = ba::make_srtp(Ssrc, Key);
        check(receive(unseeded, saved.back()) == srtp_err_status_auth_fail, "baseline did not reproduce the bug");
        srtp_dealloc(unseeded);
        for (const auto &p : saved) rejoin(p, p.index);
        rejoin(saved[3], 65535);   // wrap after the signed setup reference
        rejoin(saved[2], 65536);   // first arrival is from just before that wrap
        rejoin(saved[4], 131071);  // another wrap during setup

        auto receiver = ba::make_srtp(Ssrc, Key);
        Packet forged = saved.back();
        forged.bytes[12] ^= 1;
        check(ba::prime_srtp(receiver, Ssrc, forged.index, ba::read16(forged.bytes.data() + 2)), "prime forged packet");
        check(receive(receiver, forged) == srtp_err_status_auth_fail, "forged packet was accepted");
        check(ba::prime_srtp(receiver, Ssrc, saved.back().index, ba::read16(saved.back().bytes.data() + 2)), "re-prime failed");
        check(receive(receiver, saved.back()) == srtp_err_status_ok, "forged first packet poisoned the receiver");
        srtp_dealloc(receiver);
        srtp_dealloc(sender);
        srtp_shutdown();
        std::cout << "PASS: late join, wrap during setup, reordered first packet, authentication and replay rejection\n";
        return 0;
    } catch (const std::exception &e) {
        std::cerr << "FAIL: " << e.what() << '\n';
        return 1;
    }
}
