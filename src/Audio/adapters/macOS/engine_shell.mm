// macOS shell for the audio engine: the default output device, the system
// audio tap and a test tone. Owns OS audio only; the engine owns the samples.
// Real-time callbacks hand interleaved stereo float32 and the host time of the
// first frame at the speaker (output) or at capture (input) to the engine.
#import <AudioToolbox/AudioToolbox.h>
#import <CoreAudio/AudioHardwareTapping.h>
#import <CoreAudio/CATapDescription.h>
#import <CoreAudio/CoreAudio.h>
#import <Foundation/Foundation.h>
#include <libproc.h>
#include <mach/mach_time.h>
#include <unistd.h>

#include <atomic>
#include <cmath>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

#include "../../engine/engine.h"

namespace {
mach_timebase_info_data_t timebase() {
    static const mach_timebase_info_data_t base = [] {
        mach_timebase_info_data_t b;
        mach_timebase_info(&b);
        return b;
    }();
    return base;
}
uint64_t host_ns(uint64_t ticks) { return __uint128_t(ticks) * timebase().numer / timebase().denom; }

void check(OSStatus status, const char *what) {
    if (status != noErr) throw std::runtime_error(std::string(what) + " (OSStatus " + std::to_string(status) + ")");
}
AudioObjectPropertyAddress address(AudioObjectPropertySelector s, AudioObjectPropertyScope scope = kAudioObjectPropertyScopeGlobal) {
    return {s, scope, kAudioObjectPropertyElementMain};
}
template <class T>
T property(AudioObjectID object, AudioObjectPropertySelector s, AudioObjectPropertyScope scope = kAudioObjectPropertyScopeGlobal) {
    T value{};
    UInt32 size = sizeof(value);
    auto a = address(s, scope);
    check(AudioObjectGetPropertyData(object, &a, 0, nullptr, &size, &value), "read audio property");
    return value;
}

class MacShell final : public ba::Shell {
    AudioComponentInstance output_ = nullptr;
    uint64_t output_latency_ns_ = 0;
    // System capture.
    AudioObjectID tap_ = kAudioObjectUnknown, aggregate_ = kAudioObjectUnknown;
    AudioDeviceIOProcID io_ = nullptr;
    std::vector<float> interleaved_ = std::vector<float>(8192 * 2);
    // Test tone.
    std::atomic<bool> tone_running_{false};
    std::thread tone_;

    static OSStatus render(void *self, AudioUnitRenderActionFlags *, const AudioTimeStamp *time, UInt32, UInt32 frames,
                           AudioBufferList *data) {
        auto *shell = static_cast<MacShell *>(self);
        float *out = static_cast<float *>(data->mBuffers[0].mData);
        // The time stamp is when this buffer leaves the HAL; add the device's
        // own latency to get when its first frame reaches the speaker.
        ba_engine_render(out, frames, host_ns(time->mHostTime) + shell->output_latency_ns_);
        return noErr;
    }

    static OSStatus captured(AudioObjectID, const AudioTimeStamp *, const AudioBufferList *in, const AudioTimeStamp *time,
                             AudioBufferList *, const AudioTimeStamp *, void *self) {
        auto *shell = static_cast<MacShell *>(self);
        if (!in->mNumberBuffers) return noErr;
        const auto &first = in->mBuffers[0];
        const uint64_t host = host_ns(time->mHostTime);
        if (in->mNumberBuffers == 1 && first.mNumberChannels == 2) {
            ba_engine_capture(static_cast<const float *>(first.mData), first.mDataByteSize / 8, host);
            return noErr;
        }
        // Non-interleaved or mono: interleave into preallocated stereo frames.
        const UInt32 frames = std::min<UInt32>(first.mDataByteSize / sizeof(float) / std::max<UInt32>(first.mNumberChannels, 1), 8192);
        const float *left = static_cast<const float *>(first.mData);
        const float *right = in->mNumberBuffers > 1 ? static_cast<const float *>(in->mBuffers[1].mData) : left;
        const UInt32 stride = first.mNumberChannels ? first.mNumberChannels : 1;
        for (UInt32 i = 0; i < frames; ++i) {
            shell->interleaved_[i * 2] = left[i * stride];
            shell->interleaved_[i * 2 + 1] = in->mNumberBuffers > 1 ? right[i] : left[i * stride];
        }
        ba_engine_capture(shell->interleaved_.data(), frames, host);
        return noErr;
    }

    // Capture never includes our own playback: exclude every running audio
    // engine on this Mac (the app's, the CLI's, the Web Device's), whatever its
    // path. A feedback loop through the speakers is the failure this prevents.
    static NSArray<NSNumber *> *engine_processes() {
        auto a = address(kAudioHardwarePropertyProcessObjectList);
        UInt32 size = 0;
        check(AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &a, 0, nullptr, &size), "list audio processes");
        std::vector<AudioObjectID> processes(size / sizeof(AudioObjectID));
        check(AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, nullptr, &size, processes.data()), "read audio processes");
        NSMutableArray<NSNumber *> *excluded = [NSMutableArray array];
        for (AudioObjectID process : processes) {
            pid_t pid = 0;
            UInt32 n = sizeof(pid);
            auto p = address(kAudioProcessPropertyPID);
            if (AudioObjectGetPropertyData(process, &p, 0, nullptr, &n, &pid) != noErr) continue;
            char name[2 * MAXCOMLEN + 1] = {};
            if (proc_name(pid, name, sizeof(name)) > 0 && !strcmp(name, "ba_audio_engine")) [excluded addObject:@(process)];
        }
        return excluded;
    }

    // Engines start and stop while capturing (another Device on this Mac may
    // begin playing): keep the tap's exclusions current. Rewrite the tap only
    // when the set changes; a rewrite can restart its capture clock.
    static OSStatus processes_changed(AudioObjectID, UInt32, const AudioObjectPropertyAddress *, void *self) {
        auto *shell = static_cast<MacShell *>(self);
        if (shell->tap_ == kAudioObjectUnknown) return noErr;
        @autoreleasepool {
            CATapDescription *description = CFBridgingRelease(property<CFTypeRef>(shell->tap_, kAudioTapPropertyDescription));
            NSArray<NSNumber *> *excluded = engine_processes();
            if (![[NSSet setWithArray:description.processes ?: @[]] isEqualToSet:[NSSet setWithArray:excluded]]) {
                description.processes = excluded;
                CFTypeRef raw = (__bridge CFTypeRef)description;
                auto a = address(kAudioTapPropertyDescription);
                AudioObjectSetPropertyData(shell->tap_, &a, 0, nullptr, sizeof(raw), &raw);
            }
        }
        return noErr;
    }

   public:
    uint32_t start_output() override {
        const AudioObjectID device = property<AudioObjectID>(kAudioObjectSystemObject, kAudioHardwarePropertyDefaultOutputDevice);
        if (device == kAudioObjectUnknown) throw std::runtime_error("no default output device");
        const double rate = property<Float64>(device, kAudioDevicePropertyNominalSampleRate);
        UInt32 stream_latency = 0;
        auto streams = address(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput);
        UInt32 size = 0;
        if (AudioObjectGetPropertyDataSize(device, &streams, 0, nullptr, &size) == noErr && size >= sizeof(AudioStreamID)) {
            std::vector<AudioStreamID> ids(size / sizeof(AudioStreamID));
            if (AudioObjectGetPropertyData(device, &streams, 0, nullptr, &size, ids.data()) == noErr)
                stream_latency = property<UInt32>(ids[0], kAudioStreamPropertyLatency);
        }
        const UInt32 frames = property<UInt32>(device, kAudioDevicePropertyLatency, kAudioObjectPropertyScopeOutput) +
                              property<UInt32>(device, kAudioDevicePropertySafetyOffset, kAudioObjectPropertyScopeOutput) +
                              stream_latency;
        output_latency_ns_ = uint64_t(frames * 1e9 / rate);

        AudioComponentDescription d{kAudioUnitType_Output, kAudioUnitSubType_DefaultOutput, kAudioUnitManufacturer_Apple, 0, 0};
        AudioComponent component = AudioComponentFindNext(nullptr, &d);
        if (!component) throw std::runtime_error("default output unit unavailable");
        check(AudioComponentInstanceNew(component, &output_), "create output unit");
        // Device rate, so the unit adds no hidden resampler of its own.
        AudioStreamBasicDescription f{};
        f.mSampleRate = rate, f.mFormatID = kAudioFormatLinearPCM;
        f.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
        f.mChannelsPerFrame = 2, f.mBitsPerChannel = 32, f.mFramesPerPacket = 1, f.mBytesPerFrame = 8, f.mBytesPerPacket = 8;
        check(AudioUnitSetProperty(output_, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &f, sizeof(f)), "set output format");
        AURenderCallbackStruct callback{render, this};
        check(AudioUnitSetProperty(output_, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback, sizeof(callback)),
              "set render callback");
        check(AudioUnitInitialize(output_), "initialize output unit");
        check(AudioOutputUnitStart(output_), "start output");
        return uint32_t(rate);
    }

    void stop_output() override {
        if (!output_) return;
        AudioOutputUnitStop(output_);
        AudioUnitUninitialize(output_);
        AudioComponentInstanceDispose(output_);
        output_ = nullptr;
    }

    uint32_t start_capture(const std::string &source) override {
        if (source == "tone") return start_tone();
        if (source != "system") throw std::runtime_error("unsupported capture source " + source);
        const AudioObjectID out = property<AudioObjectID>(kAudioObjectSystemObject, kAudioHardwarePropertyDefaultOutputDevice);
        NSString *uid = CFBridgingRelease(property<CFStringRef>(out, kAudioDevicePropertyDeviceUID));
        CATapDescription *description = [[CATapDescription alloc] initExcludingProcesses:engine_processes() andDeviceUID:uid withStream:0];
        description.name = @"BEAM Audio engine capture";
        description.privateTap = YES;
        description.muteBehavior = CATapUnmuted;
        check(AudioHardwareCreateProcessTap(description, &tap_), "create system audio tap (needs System Audio Recording permission)");
        NSDictionary *composition = @{
            @kAudioAggregateDeviceNameKey : @"BEAM Audio engine capture",
            @kAudioAggregateDeviceUIDKey : NSUUID.UUID.UUIDString,
            @kAudioAggregateDeviceIsPrivateKey : @YES,
            @kAudioAggregateDeviceTapListKey : @[ @{@kAudioSubTapUIDKey : description.UUID.UUIDString} ],
            @kAudioAggregateDeviceTapAutoStartKey : @NO
        };
        check(AudioHardwareCreateAggregateDevice((__bridge CFDictionaryRef)composition, &aggregate_), "create tap device");
        const auto format = property<AudioStreamBasicDescription>(tap_, kAudioTapPropertyFormat);
        if (format.mFormatID != kAudioFormatLinearPCM || !(format.mFormatFlags & kAudioFormatFlagIsFloat) || format.mBitsPerChannel != 32)
            throw std::runtime_error("system tap is not float32");
        check(AudioDeviceCreateIOProcID(aggregate_, captured, this, &io_), "create capture callback");
        check(AudioDeviceStart(aggregate_, io_), "start system audio capture (check System Audio Recording permission)");
        auto processes = address(kAudioHardwarePropertyProcessObjectList);
        check(AudioObjectAddPropertyListener(kAudioObjectSystemObject, &processes, processes_changed, this), "watch audio processes");
        return uint32_t(format.mSampleRate);
    }

    void stop_capture() override {
        if (tone_running_.exchange(false)) tone_.join();
        if (tap_ != kAudioObjectUnknown) {
            auto processes = address(kAudioHardwarePropertyProcessObjectList);
            AudioObjectRemovePropertyListener(kAudioObjectSystemObject, &processes, processes_changed, this);
        }
        if (io_) AudioDeviceStop(aggregate_, io_), AudioDeviceDestroyIOProcID(aggregate_, io_), io_ = nullptr;
        if (aggregate_ != kAudioObjectUnknown) AudioHardwareDestroyAggregateDevice(aggregate_), aggregate_ = kAudioObjectUnknown;
        if (tap_ != kAudioObjectUnknown) AudioHardwareDestroyProcessTap(tap_), tap_ = kAudioObjectUnknown;
    }

    // 440 Hz at -12 dBFS in 10 ms blocks stamped on an ideal host clock: a
    // capture source with no device drift, for measurements.
    uint32_t start_tone() {
        constexpr uint32_t rate = 48000, frames = 480;
        tone_running_ = true;
        tone_ = std::thread([this] {
            const uint64_t start = ba::host_now_ns();
            std::vector<float> block(frames * 2);
            for (uint64_t n = 0; tone_running_; n += frames) {
                for (uint32_t i = 0; i < frames; ++i)
                    block[i * 2] = block[i * 2 + 1] = 0.25f * float(std::sin(2 * M_PI * 440.0 * double(n + i) / rate));
                const uint64_t at = start + n * 1000000000ull / rate;
                ba_engine_capture(block.data(), frames, at);
                const uint64_t next = start + (n + frames) * 1000000000ull / rate, now = ba::host_now_ns();
                if (next > now) std::this_thread::sleep_for(std::chrono::nanoseconds(next - now));
            }
        });
        return rate;
    }
};
}  // namespace

uint64_t ba::host_now_ns() { return host_ns(mach_absolute_time()); }

int main(int argc, const char **argv) {
    @autoreleasepool {
        MacShell shell;
        return ba::run(shell, argc, argv);
    }
}
