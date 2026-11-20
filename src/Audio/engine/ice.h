// Connectivity: ICE connections (libjuice) between this engine and each peer
// engine, through NATs, with STUN and TURN (relay) as configured by Erlang.
// One connection per sender-receiver pair, named by an ID Erlang chooses.
// Erlang carries the connection descriptions in signed Session messages; the
// engine never decides where to connect.
//
// libjuice runs its own thread for all connections. Received packets cross to
// the packet thread through a single-producer queue; the packet thread stays
// the only owner of stream state.
#pragma once
#include <juice/juice.h>

#include <array>
#include <atomic>
#include <cstdint>
#include <map>
#include <memory>
#include <mutex>

#include "common.h"

namespace ba {
using ConnId = uint32_t;

class Ice {
   public:
    Ice();
    ~Ice();
    // Control thread. config: stun ([host, port] or null), turn ([[host, port,
    // username, password], ...]). Events: ice_description once gathering is
    // done (send it to the peer), ice_state on every state change.
    void connect(ConnId id, const json &config);
    void set_remote(ConnId id, const std::string &description);
    void close(ConnId id);
    void close_all();
    // Any thread.
    bool send(ConnId id, const uint8_t *data, size_t size);
    // Packet thread: the next received packet, if any.
    struct Inbound {
        ConnId conn;
        uint16_t size;
        uint8_t data[1500];
    };
    bool pop(Inbound &out);
    int wake_fd() const { return wake_[0]; }  // readable while packets are queued

   private:
    struct Conn {
        Ice *ice;
        ConnId id;
        juice_agent_t *agent = nullptr;
    };
    static void on_state(juice_agent_t *agent, juice_state_t state, void *user);
    static void on_gathered(juice_agent_t *agent, void *user);
    static void on_recv(juice_agent_t *agent, const char *data, size_t size, void *user);
    void push(ConnId id, const char *data, size_t size);

    std::mutex mutex_;  // guards conns_ (create/destroy vs send)
    std::map<ConnId, std::unique_ptr<Conn>> conns_;
    static constexpr uint32_t Slots = 1024;
    std::unique_ptr<std::array<Inbound, Slots>> queue_{new std::array<Inbound, Slots>()};
    std::atomic<uint64_t> written_{0}, read_{0}, dropped_{0};
    int wake_[2] = {-1, -1};
};
}  // namespace ba
