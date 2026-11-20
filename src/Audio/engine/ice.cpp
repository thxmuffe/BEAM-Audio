#include "ice.h"

#include <fcntl.h>
#include <unistd.h>

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

namespace ba {
namespace {
// "a=candidate:... typ host ..." -> "host" (host, srflx, prflx, relay).
std::string candidate_type(const char *candidate) {
    const char *typ = strstr(candidate, " typ ");
    if (!typ) return "unknown";
    std::string type(typ + 5);
    return type.substr(0, type.find(' '));
}
const char *state_name(juice_state_t state) {
    switch (state) {
        case JUICE_STATE_DISCONNECTED: return "disconnected";
        case JUICE_STATE_GATHERING: return "gathering";
        case JUICE_STATE_CONNECTING: return "connecting";
        case JUICE_STATE_CONNECTED: return "connected";
        case JUICE_STATE_COMPLETED: return "completed";
        case JUICE_STATE_FAILED: return "failed";
    }
    return "unknown";
}
}  // namespace

Ice::Ice() {
    if (pipe(wake_)) throw std::runtime_error("pipe failed");
    for (int fd : wake_) fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);
    // libjuice logs to standard output by default, which is the engine's
    // protocol channel to Erlang: one log line corrupts it. Send it to stderr.
    juice_set_log_handler([](juice_log_level_t, const char *message) { fprintf(stderr, "libjuice: %s\n", message); });
    juice_set_log_level(getenv("BA_ICE_DEBUG") ? JUICE_LOG_LEVEL_DEBUG : JUICE_LOG_LEVEL_WARN);
}

Ice::~Ice() {
    std::lock_guard<std::mutex> lock(mutex_);
    for (auto &[id, conn] : conns_) juice_destroy(conn->agent);
    conns_.clear();
    ::close(wake_[0]), ::close(wake_[1]);
}

void Ice::connect(ConnId id, const json &config) {
    auto conn = std::make_unique<Conn>();
    conn->ice = this, conn->id = id;
    juice_config_t c{};
    c.concurrency_mode = JUICE_CONCURRENCY_MODE_POLL;  // one libjuice thread for every connection
    std::string stun_host;
    if (config.contains("stun") && config["stun"].is_array()) {
        stun_host = config["stun"].at(0).get<std::string>();
        c.stun_server_host = stun_host.c_str();
        c.stun_server_port = config["stun"].at(1).get<uint16_t>();
    }
    std::vector<std::string> strings;
    std::vector<juice_turn_server_t> turn;
    if (config.contains("turn")) {
        strings.reserve(config["turn"].size() * 3);
        for (const auto &t : config["turn"]) {
            strings.push_back(t.at(0)), strings.push_back(t.at(2)), strings.push_back(t.at(3));
            juice_turn_server_t server{};
            server.host = strings[strings.size() - 3].c_str();
            server.port = t.at(1).get<uint16_t>();
            server.username = strings[strings.size() - 2].c_str();
            server.password = strings.back().c_str();
            turn.push_back(server);
        }
        c.turn_servers = turn.data();
        c.turn_servers_count = int(turn.size());
    }
    c.cb_state_changed = on_state, c.cb_gathering_done = on_gathered, c.cb_recv = on_recv;
    c.user_ptr = conn.get();
    conn->agent = juice_create(&c);
    if (!conn->agent) fail("ICE connection could not be created");
    Conn *raw = conn.get();
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (conns_.count(id)) fail("ICE connection already exists");
        conns_[id] = std::move(conn);
    }
    if (juice_gather_candidates(raw->agent)) fail("ICE gathering failed to start");
}

void Ice::set_remote(ConnId id, const std::string &description) {
    std::lock_guard<std::mutex> lock(mutex_);
    auto it = conns_.find(id);
    if (it == conns_.end()) fail("no such ICE connection");
    if (juice_set_remote_description(it->second->agent, description.c_str())) fail("invalid ICE description");
    juice_set_remote_gathering_done(it->second->agent);  // descriptions are sent complete
}

void Ice::close(ConnId id) {
    std::unique_ptr<Conn> conn;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        auto it = conns_.find(id);
        if (it == conns_.end()) return;
        conn = std::move(it->second);
        conns_.erase(it);
    }
    juice_destroy(conn->agent);  // waits for its callbacks to finish
}

void Ice::close_all() {
    std::map<ConnId, std::unique_ptr<Conn>> all;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        all.swap(conns_);
    }
    for (auto &[id, conn] : all) juice_destroy(conn->agent);
}

bool Ice::send(ConnId id, const uint8_t *data, size_t size) {
    std::lock_guard<std::mutex> lock(mutex_);
    auto it = conns_.find(id);
    return it != conns_.end() && juice_send(it->second->agent, reinterpret_cast<const char *>(data), size) == 0;
}

bool Ice::pop(Inbound &out) {
    const uint64_t r = read_.load(std::memory_order_relaxed);
    if (r == written_.load(std::memory_order_acquire)) return false;
    out = (*queue_)[r % Slots];
    read_.store(r + 1, std::memory_order_release);
    return true;
}

void Ice::push(ConnId id, const char *data, size_t size) {
    const uint64_t w = written_.load(std::memory_order_relaxed);
    if (size > sizeof(Inbound::data) || w - read_.load(std::memory_order_acquire) >= Slots) return void(++dropped_);
    auto &slot = (*queue_)[w % Slots];
    slot.conn = id, slot.size = uint16_t(size);
    memcpy(slot.data, data, size);
    written_.store(w + 1, std::memory_order_release);
    const char byte = 1;
    (void)!write(wake_[1], &byte, 1);  // a full pipe already wakes the reader
}

void Ice::on_recv(juice_agent_t *, const char *data, size_t size, void *user) {
    auto *conn = static_cast<Conn *>(user);
    conn->ice->push(conn->id, data, size);
}

void Ice::on_gathered(juice_agent_t *agent, void *user) {
    char description[JUICE_MAX_SDP_STRING_LEN];
    if (juice_get_local_description(agent, description, sizeof(description))) return;
    emit({{"event", "ice_description"}, {"conn", static_cast<Conn *>(user)->id}, {"description", description}});
}

// The chosen path, by candidate type: host (same network), srflx/prflx
// (through NATs), relay (through TURN).
void Ice::on_state(juice_agent_t *agent, juice_state_t state, void *user) {
    json event = {{"event", "ice_state"}, {"conn", static_cast<Conn *>(user)->id}, {"state", state_name(state)}};
    if (state == JUICE_STATE_CONNECTED || state == JUICE_STATE_COMPLETED) {
        char local[JUICE_MAX_CANDIDATE_SDP_STRING_LEN], remote[JUICE_MAX_CANDIDATE_SDP_STRING_LEN];
        if (!juice_get_selected_candidates(agent, local, sizeof(local), remote, sizeof(remote)))
            event["local"] = candidate_type(local), event["remote"] = candidate_type(remote);
        char local_address[JUICE_MAX_ADDRESS_STRING_LEN], remote_address[JUICE_MAX_ADDRESS_STRING_LEN];
        if (!juice_get_selected_addresses(agent, local_address, sizeof(local_address), remote_address, sizeof(remote_address)))
            event["remote_address"] = remote_address;
    }
    emit(event);
}
}  // namespace ba
