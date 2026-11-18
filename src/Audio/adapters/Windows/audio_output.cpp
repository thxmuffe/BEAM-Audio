// Thin WASAPI output binding. Erlang supplies every presentation target; this
// helper only places each block at its target on the device timeline, plays
// silence where nothing is scheduled and reports late blocks. No retiming.
//
// Erlang port, {packet,4}, same protocol as the macOS helper:
//   args: output RATE
//   -> <<1>>                          ready
//   -> <<3,Code:32/little,Msg/binary>> failure
//   <- <<3>>  -> <<3,HostNs:64,LatencyNs:64>>   QPC clock reading, needed lead
//   <- <<2,TargetHostNs:64,Frames:32,PCM>>       planar float32 LE: L[], R[]
//   <- <<4>>  -> <<4>>                            stop, acknowledged
//   <- <<5>>  -> <<5,Scheduled:64,Played:64,Silence:64,Late:32,Queued:32,
//                  Reanchors:32,LatencyNs:64,Rate:32,Channels:32>>  stats
#include <windows.h>
#include <mmdeviceapi.h>
#include <audioclient.h>
#include <mmreg.h>
#include <ks.h>
#include <ksmedia.h>
#include <wrl/client.h>
#include <atomic>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <io.h>
#include <map>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

using Microsoft::WRL::ComPtr;
static void check(HRESULT hr) { if (FAILED(hr)) throw hr; }

static std::mutex out_lock;
static void write_all(const void* data, size_t size) {
    if (size && fwrite(data, 1, size, stdout) != size) throw E_FAIL;
}
static void reply(const std::vector<uint8_t>& payload) {
    std::lock_guard<std::mutex> guard(out_lock);
    uint32_t n = static_cast<uint32_t>(payload.size());
    uint8_t header[] = {uint8_t(n >> 24), uint8_t(n >> 16), uint8_t(n >> 8), uint8_t(n)};
    write_all(header, 4);
    write_all(payload.data(), payload.size());
    fflush(stdout);
}
static void put64(std::vector<uint8_t>& v, uint64_t x) { for (int i = 7; i >= 0; --i) v.push_back(uint8_t(x >> (8 * i))); }
static void put32(std::vector<uint8_t>& v, uint32_t x) { for (int i = 3; i >= 0; --i) v.push_back(uint8_t(x >> (8 * i))); }
static uint64_t get64(const uint8_t* p) { uint64_t x = 0; for (int i = 0; i < 8; ++i) x = (x << 8) | p[i]; return x; }
static uint32_t get32(const uint8_t* p) { uint32_t x = 0; for (int i = 0; i < 4; ++i) x = (x << 8) | p[i]; return x; }
static void fail(uint32_t code, const std::string& message) {
    std::vector<uint8_t> v{3};
    for (int i = 0; i < 4; ++i) v.push_back(uint8_t(code >> (8 * i)));
    v.insert(v.end(), message.begin(), message.end());
    reply(v);
}

// QPC as nanoseconds without overflow for long uptimes.
static int64_t qpc_ns() {
    static LARGE_INTEGER freq = [] { LARGE_INTEGER f; QueryPerformanceFrequency(&f); return f; }();
    LARGE_INTEGER c; QueryPerformanceCounter(&c);
    return (c.QuadPart / freq.QuadPart) * 1000000000LL + (c.QuadPart % freq.QuadPart) * 1000000000LL / freq.QuadPart;
}

struct Block { int64_t start; uint32_t frames; std::vector<float> left, right; };

struct Output {
    uint32_t rate = 0;
    int64_t base_ns = 0;                 // frame positions are relative to this
    std::mutex lock;
    std::map<int64_t, Block> queue;      // keyed by start frame
    std::atomic<uint64_t> scheduled{0}, played{0}, silence{0};
    std::atomic<uint32_t> late{0}, reanchors{0};
    int64_t latency_ns = 0;
    std::atomic<bool> running{true};

    int64_t frame_at(int64_t host_ns) const {
        // Nearest frame on this output's timeline; relative values keep it in range.
        int64_t rel = host_ns - base_ns;
        return rel >= 0 ? (rel * rate + 500000000LL) / 1000000000LL : -((-rel * rate + 500000000LL) / 1000000000LL);
    }
    void add(int64_t target_ns, uint32_t frames, const uint8_t* pcm) {
        Block b{frame_at(target_ns), frames, std::vector<float>(frames), std::vector<float>(frames)};
        std::memcpy(b.left.data(), pcm, frames * 4);
        std::memcpy(b.right.data(), pcm + frames * 4, frames * 4);
        std::lock_guard<std::mutex> guard(lock);
        queue[b.start] = std::move(b);
        scheduled += frames;
    }
    // Fill frames [first, first+count) interleaved stereo; drop blocks that ended.
    void render(int64_t first, uint32_t count, float* out) {
        std::memset(out, 0, size_t(count) * 2 * sizeof(float));
        uint64_t used = 0;
        std::lock_guard<std::mutex> guard(lock);
        for (auto it = queue.begin(); it != queue.end();) {
            Block& b = it->second;
            int64_t end = b.start + b.frames;
            if (end <= first) {                       // arrived after its time: never played
                late++;
                it = queue.erase(it);
                continue;
            }
            if (b.start >= first + count) break;      // ordered: nothing more yet
            int64_t from = b.start > first ? b.start : first;
            int64_t to = end < first + count ? end : first + count;
            for (int64_t f = from; f < to; ++f) {
                out[(f - first) * 2] = b.left[size_t(f - b.start)];
                out[(f - first) * 2 + 1] = b.right[size_t(f - b.start)];
            }
            used += uint64_t(to - from);
            if (to == end) it = queue.erase(it); else ++it;
        }
        played += used;
        silence += count - used;
    }
    uint32_t queued() { std::lock_guard<std::mutex> guard(lock); return uint32_t(queue.size()); }
};

static void render_loop(Output* o, IAudioClient* client, IAudioRenderClient* render, HANDLE event,
                        uint32_t buffer_frames, int64_t stream_latency_ns) {
    CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    HANDLE task = nullptr; DWORD index = 0;
    // Pro Audio scheduling class when available; harmless if refused.
    using AvSet = HANDLE(WINAPI*)(LPCWSTR, LPDWORD);
    HMODULE avrt = LoadLibraryW(L"avrt.dll");
    if (avrt) if (auto set = reinterpret_cast<AvSet>(GetProcAddress(avrt, "AvSetMmThreadCharacteristicsW"))) task = set(L"Pro Audio", &index);
    int64_t next = INT64_MIN;  // frame position of the next frame we write
    std::vector<float> scratch;
    while (o->running) {
        if (WaitForSingleObject(event, 200) != WAIT_OBJECT_0) continue;
        UINT32 padding = 0;
        if (FAILED(client->GetCurrentPadding(&padding))) break;
        uint32_t available = buffer_frames - padding;
        if (!available) continue;
        // When the first newly written frame will be heard, on the host clock.
        int64_t measured = o->frame_at(qpc_ns() + (int64_t(padding) * 1000000000LL) / o->rate + stream_latency_ns);
        // Keep a continuous frame counter; re-anchor only on real divergence (>4 ms).
        if (next == INT64_MIN || llabs(measured - next) > int64_t(o->rate) * 4 / 1000) {
            if (next != INT64_MIN) o->reanchors++;
            next = measured;
        }
        BYTE* data = nullptr;
        if (FAILED(render->GetBuffer(available, &data))) break;
        o->render(next, available, reinterpret_cast<float*>(data));
        if (FAILED(render->ReleaseBuffer(available, 0))) break;
        next += available;
    }
    if (task && avrt) if (auto revert = reinterpret_cast<BOOL(WINAPI*)(HANDLE)>(GetProcAddress(avrt, "AvRevertMmThreadCharacteristics"))) revert(task);
    CoUninitialize();
}

static bool read_exact(uint8_t* p, size_t n) {
    while (n) { size_t r = fread(p, 1, n, stdin); if (!r) return false; p += r; n -= r; }
    return true;
}

static int output(uint32_t rate) {
    check(CoInitializeEx(nullptr, COINIT_MULTITHREADED));
    ComPtr<IMMDeviceEnumerator> devices;
    check(CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL, IID_PPV_ARGS(&devices)));
    ComPtr<IMMDevice> device;
    check(devices->GetDefaultAudioEndpoint(eRender, eConsole, &device));
    ComPtr<IAudioClient> client;
    check(device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr, &client));
    // Request exactly the Mixer's format; Windows converts to the device mix format.
    WAVEFORMATEXTENSIBLE format{};
    format.Format.wFormatTag = WAVE_FORMAT_EXTENSIBLE;
    format.Format.nChannels = 2;
    format.Format.nSamplesPerSec = rate;
    format.Format.wBitsPerSample = 32;
    format.Format.nBlockAlign = 8;
    format.Format.nAvgBytesPerSec = rate * 8;
    format.Format.cbSize = sizeof(WAVEFORMATEXTENSIBLE) - sizeof(WAVEFORMATEX);
    format.Samples.wValidBitsPerSample = 32;
    format.dwChannelMask = SPEAKER_FRONT_LEFT | SPEAKER_FRONT_RIGHT;
    format.SubFormat = KSDATAFORMAT_SUBTYPE_IEEE_FLOAT;
    const REFERENCE_TIME buffer = 200000;  // 20 ms device buffer
    check(client->Initialize(AUDCLNT_SHAREMODE_SHARED,
        AUDCLNT_STREAMFLAGS_EVENTCALLBACK | AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM | AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY,
        buffer, 0, reinterpret_cast<WAVEFORMATEX*>(&format), nullptr));
    UINT32 buffer_frames = 0; check(client->GetBufferSize(&buffer_frames));
    REFERENCE_TIME latency = 0; check(client->GetStreamLatency(&latency));
    HANDLE event = CreateEventW(nullptr, FALSE, FALSE, nullptr);
    check(client->SetEventHandle(event));
    ComPtr<IAudioRenderClient> render;
    check(client->GetService(IID_PPV_ARGS(&render)));
    BYTE* data = nullptr;
    check(render->GetBuffer(buffer_frames, &data));
    check(render->ReleaseBuffer(buffer_frames, AUDCLNT_BUFFERFLAGS_SILENT));

    Output o;
    o.rate = rate;
    o.base_ns = qpc_ns();
    const int64_t stream_latency_ns = int64_t(latency) * 100;
    // A block must reach us before its first frame enters the device buffer:
    // device buffer + stream latency + one wakeup of margin.
    o.latency_ns = int64_t(buffer_frames) * 1000000000LL / rate + stream_latency_ns + 5000000;
    check(client->Start());
    std::thread worker(render_loop, &o, client.Get(), render.Get(), event, buffer_frames, stream_latency_ns);
    reply({1});

    std::vector<uint8_t> packet;
    uint8_t header[4];
    int code = 0;
    while (read_exact(header, 4)) {
        uint32_t size = get32(header);
        if (size == 0 || size > 64 * 1024 * 1024) { code = 2; break; }
        packet.resize(size);
        if (!read_exact(packet.data(), size)) break;
        switch (packet[0]) {
        case 2: {
            if (size < 13) { code = 2; break; }
            int64_t target = int64_t(get64(&packet[1]));
            uint32_t frames = get32(&packet[9]);
            if (size != 13 + size_t(frames) * 8) { code = 2; break; }
            o.add(target, frames, &packet[13]);
            continue;
        }
        case 3: {
            std::vector<uint8_t> v{3};
            put64(v, uint64_t(qpc_ns())); put64(v, uint64_t(o.latency_ns));
            reply(v);
            continue;
        }
        case 5: {
            std::vector<uint8_t> v{5};
            put64(v, o.scheduled); put64(v, o.played); put64(v, o.silence);
            put32(v, o.late); put32(v, o.queued()); put32(v, o.reanchors);
            put64(v, uint64_t(o.latency_ns)); put32(v, rate); put32(v, 2);
            reply(v);
            continue;
        }
        case 4:
            o.running = false;
            worker.join();
            client->Stop();
            reply({4});
            return 0;
        default:
            code = 2;
        }
        if (code) break;
    }
    o.running = false;
    worker.join();
    client->Stop();
    return code;
}

int main(int argc, char** argv) {
    _setmode(_fileno(stdin), _O_BINARY);
    _setmode(_fileno(stdout), _O_BINARY);
    if (argc != 3 || std::strcmp(argv[1], "output") != 0) { fail(1, "usage: output RATE"); return 1; }
    uint32_t rate = uint32_t(std::strtoul(argv[2], nullptr, 10));
    if (rate < 8000 || rate > 192000) { fail(1, "unsupported rate"); return 1; }
    try {
        return output(rate);
    } catch (HRESULT hr) {
        char text[64]; std::snprintf(text, sizeof(text), "WASAPI error 0x%08lx", static_cast<unsigned long>(hr));
        fail(uint32_t(hr), text);
        return 1;
    }
}
