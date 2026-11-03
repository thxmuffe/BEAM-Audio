// Thin WASAPI bridge. Erlang requests reads and interprets the raw buffers.
#include <windows.h>
#include <mmdeviceapi.h>
#include <audioclient.h>
#include <functiondiscoverykeys_devpkey.h>
#include <wrl/client.h>
#include <cstdio>
#include <cstdint>
#include <io.h>
#include <fcntl.h>

using Microsoft::WRL::ComPtr;
static void check(HRESULT hr) { if (FAILED(hr)) throw hr; }
static void write(const void* data, size_t size) {
    if (size && fwrite(data, 1, size, stdout) != size) throw E_FAIL;
}
// Standard Erlang {packet,4} framing: big-endian size, then a typed payload.
static void packet(BYTE type, uint32_t bytes) {
    uint32_t size = bytes + 1;
    BYTE header[] = {static_cast<BYTE>(size >> 24), static_cast<BYTE>(size >> 16),
                     static_cast<BYTE>(size >> 8), static_cast<BYTE>(size), type};
    write(header, sizeof(header));
}

static void capture() {
    ComPtr<IMMDeviceEnumerator> devices;
    check(CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL, IID_PPV_ARGS(&devices)));
    ComPtr<IMMDevice> device;
    check(devices->GetDefaultAudioEndpoint(eRender, eMultimedia, &device));
    ComPtr<IPropertyStore> properties;
    check(device->OpenPropertyStore(STGM_READ, &properties));
    PROPVARIANT name; PropVariantInit(&name);
    check(properties->GetValue(PKEY_Device_FriendlyName, &name));
    const wchar_t* source = name.vt == VT_LPWSTR ? name.pwszVal : L"Windows default output";
    ComPtr<IAudioClient> client;
    check(device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr, &client));
    WAVEFORMATEX* wave = nullptr;
    check(client->GetMixFormat(&wave));
    const WORD blockAlign = wave->nBlockAlign;
    HRESULT initialized = client->Initialize(AUDCLNT_SHAREMODE_SHARED, AUDCLNT_STREAMFLAGS_LOOPBACK,
                                            1000000, 0, wave, nullptr);
    if (FAILED(initialized)) { CoTaskMemFree(wave); PropVariantClear(&name); throw initialized; }
    uint32_t formatBytes = static_cast<uint32_t>(sizeof(WAVEFORMATEX)) + wave->cbSize;
    uint32_t nameBytes = static_cast<uint32_t>(wcslen(source) * sizeof(wchar_t));
    packet(1, 4 + formatBytes + nameBytes);
    write(&formatBytes, sizeof(formatBytes)); write(wave, formatBytes); write(source, nameBytes);
    CoTaskMemFree(wave); PropVariantClear(&name); fflush(stdout);

    ComPtr<IAudioCaptureClient> input;
    check(client->GetService(IID_PPV_ARGS(&input)));
    check(client->Start());
    // Erlang sends a {packet,4}-framed 'r' to drain packets. EOF closes capture.
    BYTE command[5];
    while (fread(command, 1, sizeof(command), stdin) == sizeof(command) &&
           command[0] == 0 && command[1] == 0 && command[2] == 0 && command[3] == 1 && command[4] == 'r') {
        UINT32 available = 0;
        check(input->GetNextPacketSize(&available));
        while (available) {
            BYTE* data = nullptr; UINT32 frames = 0; DWORD flags = 0;
            UINT64 position = 0, qpc = 0;
            check(input->GetBuffer(&data, &frames, &flags, &position, &qpc));
            uint32_t bytes = (flags & AUDCLNT_BUFFERFLAGS_SILENT) ? 0 : frames * blockAlign;
            packet(2, 24 + bytes);
            write(&frames, 4); write(&flags, 4); write(&position, 8); write(&qpc, 8); write(data, bytes);
            check(input->ReleaseBuffer(frames));
            check(input->GetNextPacketSize(&available));
        }
        packet(4, 0); fflush(stdout);
    }
    client->Stop();
}

int main() {
    _setmode(_fileno(stdin), _O_BINARY); _setmode(_fileno(stdout), _O_BINARY);
    HRESULT init = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    try {
        check(init); capture(); CoUninitialize(); return 0;
    } catch (HRESULT hr) {
        packet(3, 4); write(&hr, 4); fflush(stdout);
        if (SUCCEEDED(init)) CoUninitialize(); return 1;
    }
}
