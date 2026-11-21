// Engine: the control loop (Erlang's commands in, replies and events out), the
// packet thread, and the real-time entry points that platform shells call.
// Erlang decides; this code executes. See docs/AUDIO_ENGINE.md.
//
// Timing model: stream sample n plays at Session time anchor + delay + n / rate.
// Erlang supplies the clock mapping (host ns -> Session ns) and each stream's
// anchor and delay; capture.cpp and speaker.cpp keep their devices on it.
#include "engine.h"

#include <arpa/inet.h>
#include <netinet/in.h>
#include <poll.h>
#include <unistd.h>

#if defined(__APPLE__)
#include <pthread/qos.h>
#endif

#include <array>
#include <chrono>
#include <cstring>
#include <deque>
#include <functional>
#include <future>
#include <mutex>
#include <thread>

#include "capture.h"
#include "common.h"
#include "ice.h"
#include "net.h"
#include "recovery.h"
#include "speaker.h"
#include "term.h"
#include "timing.h"

namespace ba {
namespace {
constexpr int MaxSpeakers = 8;

// Engine threads outrank UI work: on iPhone the UI shares the CPU with the
// in-process engine. The render callback itself is Core Audio's real-time thread.
void audio_priority() {
#if defined(__APPLE__)
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
#endif
}

// OTP {packet,4} with raw read(2)/write(2) on the control connection: stdin/
// stdout of a port program, or an in-process loopback socket on iOS. C stdio
// must never touch it; diagnostics go to stderr only.
std::mutex out_mutex;
int out_fd = -1;  // guarded by out_mutex
void write_exact(int fd, const char *p, size_t n) {
    while (n) {
        const ssize_t w = write(fd, p, n);
        if (w <= 0) return;  // Erlang is gone; the read side ends this connection.
        p += w, n -= size_t(w);
    }
}
bool read_exact(int fd, uint8_t *p, size_t n) {
    while (n) {
        const ssize_t r = read(fd, p, n);
        if (r <= 0) return false;
        p += r, n -= size_t(r);
    }
    return true;
}

constexpr int MaxCaptures = 4;  // concurrent local sources (system audio, microphone, ...)
std::array<CaptureRing, MaxCaptures> capture_rings;

struct Engine {
    Shell &shell;
    Clock clock;
    Ice ice;
    std::array<std::atomic<Speaker *>, MaxSpeakers> speakers{};
    std::array<std::atomic<Sender *>, MaxCaptures> senders{};  // slot i drains capture_rings[i]
    std::atomic<uint32_t> out_rate{0};
    LevelMeter output_level;
    std::atomic<uint64_t> callbacks{0}, oversized{0};
    std::mutex task_mutex;
    std::deque<std::function<void()>> tasks;
    std::deque<std::pair<std::chrono::steady_clock::time_point, std::function<void()>>> retired;
    std::atomic<bool> stopping{false};
    std::thread packet_thread;
    explicit Engine(Shell &s) : shell(s) {}

    // Runs fn on the packet thread and waits: packet-thread state is never shared.
    void on_packet_thread(std::function<void()> fn) {
        auto done = std::make_shared<std::promise<void>>();
        auto result = done->get_future();
        {
            std::lock_guard<std::mutex> lock(task_mutex);
            tasks.push_back([fn = std::move(fn), done] {
                try {
                    fn();
                    done->set_value();
                } catch (...) {
                    done->set_exception(std::current_exception());
                }
            });
        }
        result.get();
    }

    void packet_loop() {
        for (;;) {
            std::deque<std::function<void()>> run;
            {
                std::lock_guard<std::mutex> lock(task_mutex);
                run.swap(tasks);
            }
            for (auto &task : run) task();
            const auto now = std::chrono::steady_clock::now();
            while (!retired.empty() && retired.front().first <= now) retired.front().second(), retired.pop_front();
            if (stopping.load()) return;
            pollfd p{ice.wake_fd(), POLLIN, 0};
            poll(&p, 1, 2);
            uint8_t drain[256];
            while (read(ice.wake_fd(), drain, sizeof(drain)) > 0) {
            }
            for (Ice::Inbound in; ice.pop(in);) receive(in.data, in.size, in.conn);
            for (auto &slot : speakers)
                if (Speaker *s = slot.load()) s->send_nacks(ice);
            for (int i = 0; i < MaxCaptures; ++i)
                if (Sender *s = senders[i].load()) s->drain(capture_rings[i], clock);
        }
    }

    // A packet from an ICE connection: a NACK for one of our captures, or media
    // for one of our speakers (by SSRC: streams from many senders mix here).
    void receive(uint8_t *packet, int size, ConnId from) {
        uint32_t ssrc = 0;
        const uint8_t *seqs = nullptr;
        int count = 0;
        if (parse_nack(packet, size, ssrc, seqs, count)) {
            if (Sender *s = find_sender(ssrc)) s->retransmit(seqs, count, from);
            return;
        }
        if (!rtp_ssrc(packet, size, ssrc)) return;
        for (auto &slot : speakers)
            if (Speaker *s = slot.load(); s && s->ssrc() == ssrc) return s->receive(packet, size, from);
    }

    // ---- Commands from Erlang --------------------------------------------------
    json command(const json &c) {
        const std::string op = c.at("op");
        if (op == "hello") return {{"version", 1}, {"codec", "flac"}, {"block_frames", Block}, {"bits", Bits}};
        if (op == "clock") {
            const uint64_t now = host_now_ns();
            int64_t session = 0;
            const bool mapped = clock.map(now, session);
            return {{"internal_ns", now}, {"session_ns", mapped ? json(session) : json(nullptr)}};
        }
        if (op == "clock_map") {
            clock.update(c.at("internal_ns").get<int64_t>(), c.at("session_ns").get<int64_t>(), c.at("correction_ppm").get<double>());
            return {{"revision", c.at("revision")}};
        }
        if (op == "connect") return connect(c);
        if (op == "remote") return ice.set_remote(c.at("conn"), c.at("description")), json::object();
        if (op == "disconnect") return ice.close(c.at("conn")), json::object();
        if (op == "start_speaker") return start_speaker(c);
        if (op == "stop_speaker") return stop_speaker(c.at("ssrc"));
        if (op == "start_capture") return start_capture(c);
        if (op == "stop_capture") return stop_capture(c.at("ssrc"));
        if (op == "capture_index") {
            Sender *s = find_sender(c.at("ssrc"));
            if (!s) fail("no such capture stream");
            return {{"packet_index", s->packet_index()}};
        }
        if (op == "route") return route(c.at("ssrc"), c.at("conns").get<std::vector<ConnId>>());
        if (op == "volume") return volume(c.at("ssrc"), c.at("gain"));
        if (op == "delay") return delay(c.at("ssrc"), c.at("delay_ms"));
        if (op == "test_loss") {
            on_packet_thread([&] {
                for (auto &slot : senders)
                    if (Sender *s = slot.load()) s->set_test_loss(c.at("percent"));
            });
            return json::object();
        }
        if (op == "status") return status();
        if (op == "levels") return levels();
        if (op == "response") {
            json out = {{"speakers", json::array()}};
            on_packet_thread([&] {
                for (auto &slot : speakers)
                    if (Speaker *s = slot.load()) out["speakers"].push_back(s->take_response());
            });
            return out;
        }
        if (op == "crash") crash(c.at("kind"));
        fail("unknown op " + op);
    }

    // ICE connections: Erlang names them, carries their descriptions, routes.
    json connect(const json &c) {
        ice.connect(c.at("conn"), c);
        return json::object();
    }

    // A start for a stream that already has a speaker replaces it: the newest
    // attempt owns the stream (an earlier start may have finished after its
    // caller gave up waiting).
    json start_speaker(const json &c) {
        auto s = std::make_unique<Speaker>(c, clock);
        for (auto &slot : speakers)
            if (Speaker *p = slot.load(); p && p->ssrc() == s->ssrc()) {
                slot.store(s.release());
                on_packet_thread([this, p] {
                    retired.emplace_back(std::chrono::steady_clock::now() + std::chrono::seconds(1), [p] { delete p; });
                });
                return {{"output_rate", out_rate.load()}};
            }
        bool first = true;
        for (auto &slot : speakers)
            if (slot.load()) first = false;
        if (first && !out_rate.load()) {
            output_level.clear();
            out_rate.store(shell.start_output());
        }
        for (auto &slot : speakers)
            if (!slot.load()) {
                slot.store(s.release());
                return {{"output_rate", out_rate.load()}};
            }
        fail("too many speakers");
    }

    json stop_speaker(uint32_t ssrc) {
        bool found = false, any = false;
        for (auto &slot : speakers) {
            Speaker *p = slot.load();
            if (p && p->ssrc() == ssrc) {
                slot.store(nullptr);
                found = true;
                // Free once the packet thread and render callbacks can no longer hold it.
                on_packet_thread([this, p] {
                    retired.emplace_back(std::chrono::steady_clock::now() + std::chrono::seconds(1), [p] { delete p; });
                });
            } else if (p) {
                any = true;
            }
        }
        if (!found) fail("no such speaker");
        if (!any && out_rate.load()) shell.stop_output(), out_rate.store(0);
        return json::object();
    }

    // Packet thread or control thread: senders only change on the packet thread.
    Sender *find_sender(uint32_t ssrc) {
        for (auto &slot : senders)
            if (Sender *s = slot.load(); s && s->ssrc() == ssrc) return s;
        return nullptr;
    }

    // One more local source on air; several run at once, each in its own slot.
    json start_capture(const json &c) {
        if (!clock.ready()) fail("clock mapping required before start_capture");
        if (find_sender(c.at("ssrc"))) fail("capture already running for this ssrc");
        int slot = -1;
        for (int i = 0; i < MaxCaptures && slot < 0; ++i)
            if (!senders[i].load()) slot = i;
        if (slot < 0) fail("too many captures");
        auto s = std::make_unique<Sender>(c, ice);
        Sender *raw = s.get();
        on_packet_thread([&] {
            capture_rings[slot].discard();
            senders[slot].store(s.release());
        });
        capture_rings[slot].input_level.clear();
        capture_rings[slot].meter_input.store(raw->microphone(), std::memory_order_relaxed);
        capture_rings[slot].active.store(true);
        try {
            raw->set_input_rate(shell.start_capture(slot, c.value("source", "system")));
        } catch (...) {
            capture_rings[slot].active.store(false);
            on_packet_thread([this, slot, raw] {
                senders[slot].store(nullptr);
                delete raw;
            });
            throw;
        }
        return {{"input_rate", raw->input_rate()}};
    }

    json stop_capture(uint32_t ssrc) {
        for (int i = 0; i < MaxCaptures; ++i)
            if (Sender *s = senders[i].load(); s && s->ssrc() == ssrc) {
                capture_rings[i].active.store(false);
                shell.stop_capture(i);
                on_packet_thread([this, i, s] {
                    senders[i].store(nullptr);
                    delete s;
                });
                return json::object();
            }
        fail("no such capture stream");
    }

    // The ICE connections (one per receiver) a capture is sent on.
    json route(uint32_t ssrc, std::vector<ConnId> conns) {
        on_packet_thread([&] {
            Sender *s = find_sender(ssrc);
            if (!s) fail("no such capture stream");
            s->set_routes(std::move(conns));
        });
        return json::object();
    }

    json volume(uint32_t ssrc, float gain) {
        for (auto &slot : speakers)
            if (Speaker *s = slot.load(); s && s->ssrc() == ssrc) return s->set_gain(gain), json::object();
        fail("no such speaker");
    }

    json delay(uint32_t ssrc, int64_t delay_ms) {
        if (delay_ms < 0 || delay_ms > 3000) fail("delay must be 0-3000 ms");
        for (auto &slot : speakers)
            if (Speaker *s = slot.load(); s && s->ssrc() == ssrc) return s->set_delay(delay_ms), json::object();
        fail("no such speaker");
    }

    json levels() {
        json out = json::object();
        const uint64_t now = host_now_ns();
        if (out_rate.load()) {
            if (auto level = output_level.read(now); !level.is_null()) out["speaker"] = level;
        }
        for (int i = 0; i < MaxCaptures; ++i) {
            if (Sender *s = senders[i].load()) {
                auto level = s->microphone() ? capture_rings[i].input_level.read(now) : s->capture_level(now);
                if (!level.is_null()) out[s->microphone() ? "microphone" : "broadcast"] = level;
            }
        }
        return out;
    }

    json status() {
        json out = {{"clock_ready", clock.ready()}, {"output_rate", out_rate.load()}, {"callbacks", callbacks.load()},
                    {"oversized_callbacks", oversized.load()}, {"speakers", json::array()}};
        for (auto &slot : speakers)
            if (Speaker *s = slot.load()) out["speakers"].push_back(s->status());
        out["captures"] = json::array();
        for (int i = 0; i < MaxCaptures; ++i)
            if (Sender *s = senders[i].load()) out["captures"].push_back(s->status(capture_rings[i]));
        return out;
    }

    // The owner is gone: release devices and streams; the next owner starts clean.
    void reset() {
        for (auto &slot : senders)
            if (Sender *s = slot.load()) stop_capture(s->ssrc());
        for (auto &slot : speakers)
            if (Speaker *p = slot.load()) stop_speaker(p->ssrc());
        if (out_rate.load()) shell.stop_output(), out_rate.store(0);
        on_packet_thread([this] {
            ice.close_all();
        });
    }

    // Development check of crash reporting; Erlang's tests send this.
    [[noreturn]] static void crash(const std::string &kind) {
        if (kind == "exception") throw std::logic_error("requested test exception");
        if (kind == "thread") std::thread([] { throw std::logic_error("requested test exception on a thread"); }).join();
        if (kind == "abort") std::abort();
        volatile int *null = nullptr;
        *null = 1;
        std::abort();
    }
};

Engine *engine = nullptr;
}  // namespace

void emit(const json &event) {
    const std::string body = encode(event);
    const uint32_t n = uint32_t(body.size());
    const char header[4] = {char(n >> 24), char(n >> 16), char(n >> 8), char(n)};
    std::lock_guard<std::mutex> lock(out_mutex);
    if (out_fd < 0) return;
    write_exact(out_fd, header, 4);
    write_exact(out_fd, body.data(), n);
}

namespace {
Engine &start_engine(Shell &shell, const char *crash_file) {
    install_crash_handlers(crash_file);
    if (srtp_init() != srtp_err_status_ok) throw std::runtime_error("srtp_init failed");
    term_init();
    static Engine instance(shell);
    engine = &instance;
    instance.packet_thread = std::thread([] {
        audio_priority();
        engine->packet_loop();
    });
    return instance;
}

// One owner's control connection, until it closes; then everything is released.
void serve(Engine &instance, int in, int out) {
    audio_priority();
    {
        std::lock_guard<std::mutex> lock(out_mutex);
        out_fd = out;
    }
    std::vector<uint8_t> body;
    for (;;) {
        uint8_t header[4];
        if (!read_exact(in, header, 4)) break;
        body.resize(read32(header));
        if (!read_exact(in, body.data(), body.size())) break;
        const json c = decode(body);  // malformed control is a bug: crash
        json shown = c;
        if (shown.contains("key")) shown["key"] = "(redacted)";
        remember_command(shown.dump(-1, ' ', false, json::error_handler_t::replace));
        json reply;
        try {
            reply = instance.command(c);
            reply["event"] = "ok";
        } catch (const std::runtime_error &e) {  // command or OS refusal: reply; other faults crash
            reply = {{"event", "error"}, {"error", e.what()}};
        }
        reply["id"] = c.at("id");
        reply["op"] = c.at("op");
        emit(reply);
    }
    {
        std::lock_guard<std::mutex> lock(out_mutex);
        out_fd = -1;
    }
    instance.reset();
}
}  // namespace

int run(Shell &shell, int argc, const char **argv) {
    const char *crash_file = nullptr;
    for (int i = 1; i + 1 < argc; ++i)
        if (!strcmp(argv[i], "--crash-file")) crash_file = argv[i + 1];
    Engine &instance = start_engine(shell, crash_file);
    serve(instance, 0, 1);  // until Erlang closes the port
    instance.stopping.store(true);
    instance.packet_thread.join();
    return 0;
}

uint16_t serve_loopback(Shell &shell, const char *crash_file) {
    const int listener = ::socket(AF_INET, SOCK_STREAM, 0);
    sockaddr_in a{};
    a.sin_family = AF_INET, a.sin_addr.s_addr = htonl(INADDR_LOOPBACK), a.sin_port = 0;
    socklen_t size = sizeof(a);
    if (listener < 0 || bind(listener, reinterpret_cast<sockaddr *>(&a), sizeof(a)) || listen(listener, 1) ||
        getsockname(listener, reinterpret_cast<sockaddr *>(&a), &size))
        throw std::runtime_error("engine control listener failed");
    Engine &instance = start_engine(shell, crash_file);
    std::thread([&instance, listener] {
        for (;;) {
            const int fd = accept(listener, nullptr, nullptr);
            if (fd < 0) continue;
            int on = 1;
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof(on));
            serve(instance, fd, fd);
            close(fd);
        }
    }).detach();
    return ntohs(a.sin_port);
}
}  // namespace ba

extern "C" void ba_engine_render(float *out, uint32_t frames, uint64_t host_time_ns) {
    memset(out, 0, size_t(frames) * ba::Channels * sizeof(float));
    ba::Engine *e = ba::engine;
    if (!e) return;
    e->callbacks.fetch_add(1, std::memory_order_relaxed);
    if (frames > ba::MaxCallback) return void(e->oversized.fetch_add(1, std::memory_order_relaxed));
    const uint32_t rate = e->out_rate.load(std::memory_order_relaxed);
    if (!rate) return;
    int64_t present = 0;
    if (e->clock.map(host_time_ns, present)) {
        unsigned inputs = 0;
        for (auto &slot : e->speakers)
            if (ba::Speaker *s = slot.load(std::memory_order_acquire)) inputs += s->render(out, frames, present, rate);
        if (inputs > 1) {
            const float scale = 1.0f / float(inputs);
            for (size_t i = 0; i < size_t(frames) * ba::Channels; ++i) out[i] = std::clamp(out[i] * scale, -1.0f, 1.0f);
        }
    }
    e->output_level.sample(out, frames * ba::Channels, ba::host_now_ns());
}

extern "C" void ba_engine_capture(int slot, const float *in, uint32_t frames, uint64_t host_time_ns) {
    if (slot < 0 || slot >= ba::MaxCaptures) return;
    auto &ring = ba::capture_rings[size_t(slot)];
    if (!ring.active.load(std::memory_order_acquire)) return;
    if (ring.meter_input.load(std::memory_order_relaxed))
        ring.input_level.sample(in, frames * ba::Channels, ba::host_now_ns());
    ring.push(in, frames, host_time_ns);
}
