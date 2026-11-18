// Thin WASAPI capture binding for the shared pipeline (ba_windows_input).
// It delivers PCM with the QPC time of each packet's first frame; Erlang maps
// that clock and owns publication, presentation targets and permissions.
//
// Erlang port, {packet,4}; integers little-endian:
//   args: mic | loopback EXCLUDE_PID
//     mic      default capture endpoint, 48 kHz float32 mono
//     loopback system output of every process except EXCLUDE_PID's tree
//              (this Device's own Session playback), 48 kHz float32 stereo
//   -> <<1,Rate:32,Channels:32>>                         ready (float32_le PCM)
//   -> <<2,QpcNs:64,Frames:32,Flags:32,PCM/binary>>      captured frames
//   <- <<3>>  -> <<3,QpcNs:64>>                          clock reading
//   -> <<5,Code:32/signed,Message/binary>>               failure, then exit
//   <- <<"s">> -> <<6>>                                   stop, acknowledged
#include <windows.h>
#include <mmdeviceapi.h>
#include <audioclient.h>
#include <audioclientactivationparams.h>
#include <mmreg.h>
#include <ks.h>
#include <ksmedia.h>
#include <wrl/client.h>
#include <wrl/implements.h>
#include <atomic>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <io.h>
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
static void send_packet(const std::vector<uint8_t>& head, const void* body = nullptr, size_t body_size = 0) {
    std::lock_guard<std::mutex> guard(out_lock);
    uint32_t n = uint32_t(head.size() + body_size);
    uint8_t size[] = {uint8_t(n >> 24), uint8_t(n >> 16), uint8_t(n >> 8), uint8_t(n)};
    write_all(size, 4);
    write_all(head.data(), head.size());
    write_all(body, body_size);
    fflush(stdout);
}
static void put32(std::vector<uint8_t>& v, uint32_t x) { for (int i = 0; i < 4; ++i) v.push_back(uint8_t(x >> (8 * i))); }
static void put64(std::vector<uint8_t>& v, uint64_t x) { for (int i = 0; i < 8; ++i) v.push_back(uint8_t(x >> (8 * i))); }
static void fail(int32_t code, const std::string& message) {
    std::vector<uint8_t> v{5}; put32(v, uint32_t(code));
    send_packet(v, message.data(), message.size());
}

// QPC in nanoseconds, the same clock as ba_audio_output.exe.
static int64_t qpc_ns() {
    static LARGE_INTEGER freq = [] { LARGE_INTEGER f; QueryPerformanceFrequency(&f); return f; }();
    LARGE_INTEGER c; QueryPerformanceCounter(&c);
    return (c.QuadPart / freq.QuadPart) * 1000000000LL + (c.QuadPart % freq.QuadPart) * 1000000000LL / freq.QuadPart;
}

static WAVEFORMATEXTENSIBLE float_format(uint32_t rate, uint16_t channels) {
    WAVEFORMATEXTENSIBLE f{};
    f.Format.wFormatTag = WAVE_FORMAT_EXTENSIBLE;
    f.Format.nChannels = channels;
    f.Format.nSamplesPerSec = rate;
    f.Format.wBitsPerSample = 32;
    f.Format.nBlockAlign = WORD(4 * channels);
    f.Format.nAvgBytesPerSec = rate * 4 * channels;
    f.Format.cbSize = sizeof(WAVEFORMATEXTENSIBLE) - sizeof(WAVEFORMATEX);
    f.Samples.wValidBitsPerSample = 32;
    f.dwChannelMask = channels == 1 ? SPEAKER_FRONT_CENTER : (SPEAKER_FRONT_LEFT | SPEAKER_FRONT_RIGHT);
    f.SubFormat = KSDATAFORMAT_SUBTYPE_IEEE_FLOAT;
    return f;
}

// ActivateAudioInterfaceAsync completion, needed for process loopback.
class Activation : public Microsoft::WRL::RuntimeClass<Microsoft::WRL::RuntimeClassFlags<Microsoft::WRL::ClassicCom>,
                                                       Microsoft::WRL::FtmBase, IActivateAudioInterfaceCompletionHandler> {
public:
    HANDLE done = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    HRESULT result = E_FAIL;
    ComPtr<IAudioClient> client;
    ~Activation() { CloseHandle(done); }
    STDMETHOD(ActivateCompleted)(IActivateAudioInterfaceAsyncOperation* operation) override {
        ComPtr<IUnknown> unknown;
        HRESULT activated = E_FAIL;
        result = operation->GetActivateResult(&activated, &unknown);
        if (SUCCEEDED(result)) result = activated;
        if (SUCCEEDED(result)) result = unknown.As(&client);
        SetEvent(done);
        return S_OK;
    }
};

static ComPtr<IAudioClient> loopback_client(DWORD exclude) {
    AUDIOCLIENT_ACTIVATION_PARAMS params{};
    params.ActivationType = AUDIOCLIENT_ACTIVATION_TYPE_PROCESS_LOOPBACK;
    params.ProcessLoopbackParams.TargetProcessId = exclude;
    params.ProcessLoopbackParams.ProcessLoopbackMode = PROCESS_LOOPBACK_MODE_EXCLUDE_TARGET_PROCESS_TREE;
    PROPVARIANT activate{};
    activate.vt = VT_BLOB;
    activate.blob.cbSize = sizeof(params);
    activate.blob.pBlobData = reinterpret_cast<BYTE*>(&params);
    auto handler = Microsoft::WRL::Make<Activation>();
    ComPtr<IActivateAudioInterfaceAsyncOperation> operation;
    check(ActivateAudioInterfaceAsync(VIRTUAL_AUDIO_DEVICE_PROCESS_LOOPBACK, __uuidof(IAudioClient),
                                      &activate, handler.Get(), &operation));
    if (WaitForSingleObject(handler->done, 5000) != WAIT_OBJECT_0) throw HRESULT(E_ABORT);
    check(handler->result);
    return handler->client;
}

static ComPtr<IAudioClient> microphone_client() {
    ComPtr<IMMDeviceEnumerator> devices;
    check(CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL, IID_PPV_ARGS(&devices)));
    ComPtr<IMMDevice> device;
    check(devices->GetDefaultAudioEndpoint(eCapture, eConsole, &device));
    ComPtr<IAudioClient> client;
    check(device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr, &client));
    return client;
}

static std::atomic<bool> running{true};

// Linear device-frame -> host-time mapping. WASAPI's per-packet QPC stamp
// jitters by about one frame; deriving each packet's time from its exact device
// frame position keeps consecutive blocks contiguous (no false overlaps/gaps).
// The mapping is steered slowly toward the stamps (device clock drift) and
// re-anchored only on a discontinuity or an error above 2 ms, which is
// reported as flag REANCHORED so Erlang can count it. Every packet still
// carries its own capture time; nothing is inferred from neighbouring packets.
static const uint32_t REANCHORED = 0x100;
struct FrameClock {
    bool anchored = false;
    double base_ns = 0;      // host time of frame base_pos
    uint64_t base_pos = 0;
    uint32_t rate = 48000;
    // Returns the host time of frame pos; sets reanchored when it jumped.
    int64_t at(uint64_t pos, int64_t measured, bool discontinuity, bool& reanchored) {
        double predicted = base_ns + double(int64_t(pos - base_pos)) * 1e9 / rate;
        double error = double(measured) - predicted;
        if (!anchored) { anchored = true; base_ns = double(measured); base_pos = pos; return measured; }
        reanchored = discontinuity || error > 2e6 || error < -2e6;
        if (reanchored) { base_ns = double(measured); base_pos = pos; return measured; }
        base_ns += 0.01 * error;   // ~100-packet time constant; << 1 frame per packet
        return int64_t(predicted + 0.01 * error + 0.5);
    }
};

static void capture_loop(IAudioClient* client, IAudioCaptureClient* input, HANDLE event, uint32_t channels, uint32_t rate) {
    CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    const uint32_t frame_bytes = 4 * channels;
    std::vector<uint8_t> silence;
    FrameClock clock; clock.rate = rate;
    // Our own count of delivered frames is the position: contiguous by
    // construction. (u64DevicePosition is not usable for process loopback.)
    // Real losses arrive flagged as discontinuities or exceed the 2 ms bound.
    uint64_t delivered = 0;
    while (running) {
        if (WaitForSingleObject(event, 200) != WAIT_OBJECT_0) continue;
        UINT32 available = 0;
        if (FAILED(input->GetNextPacketSize(&available))) { fail(-1, "capture device lost"); break; }
        while (available && running) {
            BYTE* data = nullptr; UINT32 frames = 0; DWORD flags = 0; UINT64 position = 0, qpc = 0;
            if (FAILED(input->GetBuffer(&data, &frames, &flags, &position, &qpc))) { fail(-1, "capture read failed"); running = false; break; }
            // u64QPCPosition is QPC in 100 ns units at the first frame's capture.
            int64_t measured = (flags & AUDCLNT_BUFFERFLAGS_TIMESTAMP_ERROR) ? qpc_ns() : int64_t(qpc) * 100;
            bool reanchored = false;
            (void)position;
            int64_t at = clock.at(delivered, measured, (flags & (AUDCLNT_BUFFERFLAGS_DATA_DISCONTINUITY | AUDCLNT_BUFFERFLAGS_TIMESTAMP_ERROR)) != 0, reanchored);
            size_t bytes = size_t(frames) * frame_bytes;
            const void* pcm = data;
            if (flags & AUDCLNT_BUFFERFLAGS_SILENT) { silence.assign(bytes, 0); pcm = silence.data(); }
            std::vector<uint8_t> head{2}; put64(head, uint64_t(at)); put32(head, frames); put32(head, flags | (reanchored ? REANCHORED : 0));
            try { send_packet(head, pcm, bytes); } catch (...) { running = false; }
            input->ReleaseBuffer(frames);
            delivered += frames;
            if (FAILED(input->GetNextPacketSize(&available))) { available = 0; }
        }
    }
    client->Stop();
    CoUninitialize();
}

static bool read_exact(uint8_t* p, size_t n) {
    while (n) { size_t r = fread(p, 1, n, stdin); if (!r) return false; p += r; n -= r; }
    return true;
}

static int capture(bool loopback, DWORD exclude) {
    check(CoInitializeEx(nullptr, COINIT_MULTITHREADED));
    const uint32_t rate = 48000;
    const uint16_t channels = loopback ? 2 : 1;
    ComPtr<IAudioClient> client = loopback ? loopback_client(exclude) : microphone_client();
    WAVEFORMATEXTENSIBLE format = float_format(rate, channels);
    DWORD flags = AUDCLNT_STREAMFLAGS_EVENTCALLBACK | AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM | AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY;
    if (loopback) flags |= AUDCLNT_STREAMFLAGS_LOOPBACK;
    check(client->Initialize(AUDCLNT_SHAREMODE_SHARED, flags, 200000, 0,
                             reinterpret_cast<WAVEFORMATEX*>(&format), nullptr));
    HANDLE event = CreateEventW(nullptr, FALSE, FALSE, nullptr);
    check(client->SetEventHandle(event));
    ComPtr<IAudioCaptureClient> input;
    check(client->GetService(IID_PPV_ARGS(&input)));
    check(client->Start());
    { std::vector<uint8_t> ready{1}; put32(ready, rate); put32(ready, channels); send_packet(ready); }
    std::thread worker(capture_loop, client.Get(), input.Get(), event, channels, rate);

    uint8_t header[4];
    std::vector<uint8_t> command;
    while (read_exact(header, 4)) {
        uint32_t size = (uint32_t(header[0]) << 24) | (uint32_t(header[1]) << 16) | (uint32_t(header[2]) << 8) | header[3];
        if (size == 0 || size > 64) break;
        command.resize(size);
        if (!read_exact(command.data(), size)) break;
        if (command[0] == 3) {
            std::vector<uint8_t> v{3}; put64(v, uint64_t(qpc_ns())); send_packet(v);
        } else if (command[0] == 's') {
            running = false;
            worker.join();
            send_packet({6});
            return 0;
        }
    }
    running = false;
    worker.join();
    return 0;
}

int main(int argc, char** argv) {
    _setmode(_fileno(stdin), _O_BINARY);
    _setmode(_fileno(stdout), _O_BINARY);
    bool loopback = argc == 3 && std::strcmp(argv[1], "loopback") == 0;
    bool mic = argc == 2 && std::strcmp(argv[1], "mic") == 0;
    if (!loopback && !mic) { fail(1, "usage: mic | loopback EXCLUDE_PID"); return 1; }
    try {
        return capture(loopback, loopback ? DWORD(std::strtoul(argv[2], nullptr, 10)) : 0);
    } catch (HRESULT hr) {
        char text[96];
        std::snprintf(text, sizeof(text), "%s WASAPI error 0x%08lx", loopback ? "System audio" : "Microphone",
                      static_cast<unsigned long>(hr));
        fail(int32_t(hr), text);
        return 1;
    }
}
