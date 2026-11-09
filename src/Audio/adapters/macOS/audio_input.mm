// Core Audio binding only: tap/device lifetime and bounded raw-buffer transfer.
#import <Foundation/Foundation.h>
#import <CoreAudio/CoreAudio.h>
#import <CoreAudio/CATapDescription.h>
#import <CoreAudio/AudioHardwareTapping.h>
#include <mach/mach_time.h>
#include <array>
#include <atomic>
#include <mutex>
#include <memory>
#include <cstdio>
#include <cstring>
#include <csignal>

struct Failure { OSStatus code; const char *operation; };
static void check(OSStatus code, const char *operation) {
    if (code != noErr) throw Failure{code, operation};
}
static AudioObjectPropertyAddress address(AudioObjectPropertySelector selector,
        AudioObjectPropertyScope scope = kAudioObjectPropertyScopeGlobal) {
    return {selector, scope, kAudioObjectPropertyElementMain};
}
template<class T> static T property(AudioObjectID object, AudioObjectPropertySelector selector) {
    T value{}; UInt32 size = sizeof(value); auto a = address(selector);
    check(AudioObjectGetPropertyData(object, &a, 0, nullptr, &size, &value), "Read audio property");
    return value;
}
static void writeBytes(const void *data, size_t size) {
    if (size && fwrite(data, 1, size, stdout) != size) throw Failure{-1, "Write capture pipe"};
}
// OTP {packet,4}; payload integer/ASBD values use this Apple Silicon host's LE ABI.
static void wirePacket(uint8_t type, const void *data, uint32_t bytes) {
    uint32_t size = bytes + 1;
    uint8_t header[] = {uint8_t(size >> 24), uint8_t(size >> 16), uint8_t(size >> 8), uint8_t(size), type};
    writeBytes(header, sizeof(header)); writeBytes(data, bytes);
}

#ifdef BA_OPUS_COMPARISON
#include "opus_capture.inc"
#else
static void packet(uint8_t type, const void *data, uint32_t bytes) { wirePacket(type, data, bytes); }
#endif

static constexpr size_t Capacity = 65536;
struct Slot { uint32_t size = 0; std::array<uint8_t, Capacity> data; };
class Capture {
    AudioObjectID tap = kAudioObjectUnknown, device = kAudioObjectUnknown;
    AudioDeviceIOProcID callback = nullptr;
    std::mutex mutex;
    std::array<Slot, 8> slots;
    size_t head = 0, count = 0;
    std::atomic<uint64_t> dropped{0};
    std::atomic<bool> changed{false};
    bool watchingOutput = false, watchingFormat = false;
    static OSStatus changedProperty(AudioObjectID, UInt32, const AudioObjectPropertyAddress *, void *context) {
        static_cast<Capture *>(context)->changed.store(true); return noErr;
    }
    static OSStatus input(AudioObjectID, const AudioTimeStamp *, const AudioBufferList *buffers,
            const AudioTimeStamp *time, AudioBufferList *, const AudioTimeStamp *, void *context) {
        static_cast<Capture *>(context)->copy(buffers, time); return noErr;
    }
    void copy(const AudioBufferList *buffers, const AudioTimeStamp *time) {
        // Never block, allocate or write to a pipe on the Core Audio callback.
        std::unique_lock<std::mutex> lock(mutex, std::try_to_lock);
        if (!lock.owns_lock() || count == slots.size()) { ++dropped; return; }
        uint32_t size = 8 + 8 + 8 + 4 + 4;
        for (UInt32 i = 0; i < buffers->mNumberBuffers; ++i) {
            const auto &b = buffers->mBuffers[i];
            if (!b.mData || size > Capacity - 8 || b.mDataByteSize > Capacity - size - 8) { ++dropped; return; }
            size += 8 + b.mDataByteSize;
        }
        auto &slot = slots[(head + count) % slots.size()];
        uint8_t *p = slot.data.data();
        auto put = [&p](const auto &value) { memcpy(p, &value, sizeof(value)); p += sizeof(value); };
        put(time->mHostTime); put(time->mSampleTime);
        const uint64_t drops = dropped.load(); put(drops);
        put(time->mFlags); put(buffers->mNumberBuffers);
        for (UInt32 i = 0; i < buffers->mNumberBuffers; ++i) {
            const auto &b = buffers->mBuffers[i]; put(b.mNumberChannels); put(b.mDataByteSize);
            memcpy(p, b.mData, b.mDataByteSize); p += b.mDataByteSize;
        }
        slot.size = size; ++count;
    }
public:
    ~Capture() {
        auto out = address(kAudioHardwarePropertyDefaultOutputDevice);
        if (watchingOutput) AudioObjectRemovePropertyListener(kAudioObjectSystemObject, &out, changedProperty, this);
        auto fmt = address(kAudioTapPropertyFormat);
        if (watchingFormat) AudioObjectRemovePropertyListener(tap, &fmt, changedProperty, this);
        if (callback) { AudioDeviceStop(device, callback); AudioDeviceDestroyIOProcID(device, callback); }
        if (device != kAudioObjectUnknown) AudioHardwareDestroyAggregateDevice(device);
        if (tap != kAudioObjectUnknown) AudioHardwareDestroyProcessTap(tap);
    }
    void run() {
        const AudioObjectID output = property<AudioObjectID>(kAudioObjectSystemObject, kAudioHardwarePropertyDefaultOutputDevice);
        if (output == kAudioObjectUnknown) throw Failure{-1, "No default output device"};
        NSString *uid = CFBridgingRelease(property<CFStringRef>(output, kAudioDevicePropertyDeviceUID));
        CATapDescription *description = [[CATapDescription alloc] initExcludingProcesses:@[] andDeviceUID:uid withStream:0];
        description.name = @"BEAM Audio default output";
        description.privateTap = YES; description.muteBehavior = CATapUnmuted;
        check(AudioHardwareCreateProcessTap(description, &tap), "Create system audio tap (requires System Audio Recording permission)");
        NSDictionary *composition = @{
            @kAudioAggregateDeviceNameKey: @"BEAM Audio capture",
            @kAudioAggregateDeviceUIDKey: NSUUID.UUID.UUIDString,
            @kAudioAggregateDeviceIsPrivateKey: @YES,
            @kAudioAggregateDeviceTapListKey: @[@{@kAudioSubTapUIDKey: description.UUID.UUIDString}],
            @kAudioAggregateDeviceTapAutoStartKey: @NO
        };
        check(AudioHardwareCreateAggregateDevice((__bridge CFDictionaryRef)composition, &device), "Create tap input device");
        check(AudioDeviceCreateIOProcID(device, input, this, &callback), "Create capture callback");
        check(AudioDeviceStart(device, callback), "Start system audio recording; check macOS privacy permission");
        auto out = address(kAudioHardwarePropertyDefaultOutputDevice);
        check(AudioObjectAddPropertyListener(kAudioObjectSystemObject, &out, changedProperty, this), "Watch default output");
        watchingOutput = true;
        auto fmt = address(kAudioTapPropertyFormat);
        check(AudioObjectAddPropertyListener(tap, &fmt, changedProperty, this), "Watch tap format");
        watchingFormat = true;
        const auto format = property<AudioStreamBasicDescription>(tap, kAudioTapPropertyFormat);
        { std::lock_guard<std::mutex> lock(mutex); head = 0; count = 0; }
        mach_timebase_info_data_t base; mach_timebase_info(&base);
        // ASBD's defined members, not sizeof(struct)/ABI padding.
        std::array<uint8_t, 44> metadata{}; uint8_t *p = metadata.data();
        auto put = [&p](const auto &value) { memcpy(p, &value, sizeof(value)); p += sizeof(value); };
        put(format.mSampleRate); put(format.mFormatID); put(format.mFormatFlags);
        put(format.mBytesPerPacket); put(format.mFramesPerPacket); put(format.mBytesPerFrame);
        put(format.mChannelsPerFrame); put(format.mBitsPerChannel); put(base.numer); put(base.denom);
        packet(1, metadata.data(), uint32_t(p - metadata.data())); fflush(stdout);
        Slot scratch;
        uint8_t command[5];
        while (fread(command, 1, sizeof(command), stdin) == sizeof(command)) {
            if (memcmp(command, "\0\0\0\1r", 5)) throw Failure{-1, "Invalid capture command"};
            if (changed.load()) throw Failure{-1, "Default output or tap format changed; stop/start broadcast"};
            const uint64_t host = mach_absolute_time(); packet(5, &host, sizeof(host));
            // Drain at most one ring's worth per credit, then yield to Erlang.
            for (size_t n = 0; n < slots.size(); ++n) {
                {
                    std::lock_guard<std::mutex> lock(mutex);
                    if (!count) break;
                    scratch.size = slots[head].size;
                    memcpy(scratch.data.data(), slots[head].data.data(), scratch.size);
                    head = (head + 1) % slots.size(); --count;
                }
                packet(2, scratch.data.data(), scratch.size);
            }
            packet(4, nullptr, 0); fflush(stdout);
        }
    }
};

int main() {
    signal(SIGPIPE, SIG_IGN);
    @autoreleasepool {
        try {
            if (@available(macOS 14.2, *)) {
                auto capture = std::make_unique<Capture>(); capture->run(); return 0;
            }
            throw Failure{-1, "System audio capture requires macOS 14.2 or newer"};
        } catch (Failure failure) {
            try {
                const uint32_t size = uint32_t(strlen(failure.operation)) + 4;
                std::array<uint8_t, 512> error{};
                memcpy(error.data(), &failure.code, 4);
                memcpy(error.data() + 4, failure.operation, size - 4);
                packet(3, error.data(), size); fflush(stdout);
            } catch (...) {}
            return 1;
        }
    }
}
