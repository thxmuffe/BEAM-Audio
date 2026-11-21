// macOS shell for the audio engine: the default output device, the system
// audio tap, the default microphone and a test tone. Owns OS audio only; the engine owns the samples.
// Real-time callbacks hand interleaved stereo float32 and the host time of the
// first frame at the speaker (output) or at capture (input) to the engine.
#import <AVFoundation/AVFoundation.h>
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
#include <map>
#include <memory>
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
std::vector<AudioObjectID> object_list(AudioObjectID object, AudioObjectPropertyAddress property) {
    UInt32 size = 0;
    check(AudioObjectGetPropertyDataSize(object, &property, 0, nullptr, &size), "size audio object list");
    std::vector<AudioObjectID> ids(size / sizeof(AudioObjectID));
    if (size) check(AudioObjectGetPropertyData(object, &property, 0, nullptr, &size, ids.data()), "read audio object list");
    ids.resize(size / sizeof(AudioObjectID));
    return ids;
}

// One running capture: a system tap, the microphone or the test tone. Several
// run at once, each feeding its own engine slot.
struct Capture {
    int slot = -1;
    AudioObjectID tap = kAudioObjectUnknown, aggregate = kAudioObjectUnknown, device = kAudioObjectUnknown;
    AudioObjectID tapped_output = kAudioObjectUnknown;
    AudioDeviceIOProcID io = nullptr;
    uint64_t latency_ns = 0;  // input path before the callback sees a frame
    std::vector<float> interleaved = std::vector<float>(8192 * 2);
    std::atomic<bool> tone_running{false};
    std::thread tone;
};

// Frames between the hardware and the callback in one scope of a device.
UInt32 device_latency(AudioObjectID device, AudioObjectPropertyScope scope) {
    UInt32 stream_latency = 0;
    auto streams = address(kAudioDevicePropertyStreams, scope);
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(device, &streams, 0, nullptr, &size) == noErr && size >= sizeof(AudioStreamID)) {
        std::vector<AudioStreamID> ids(size / sizeof(AudioStreamID));
        if (AudioObjectGetPropertyData(device, &streams, 0, nullptr, &size, ids.data()) == noErr)
            stream_latency = property<UInt32>(ids[0], kAudioStreamPropertyLatency);
    }
    return property<UInt32>(device, kAudioDevicePropertyLatency, scope) + property<UInt32>(device, kAudioDevicePropertySafetyOffset, scope) +
           stream_latency;
}

// Capture never includes our own playback: exclude every running audio engine
// on this Mac (the app's, the CLI's, the Web Device's), whatever its path. A
// feedback loop through the speakers is the failure this prevents.
NSArray<NSNumber *> *engine_processes() {
    const auto processes = object_list(kAudioObjectSystemObject, address(kAudioHardwarePropertyProcessObjectList));
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

bool music_on_output(AudioObjectID output) {
    for (AudioObjectID process : object_list(kAudioObjectSystemObject, address(kAudioHardwarePropertyProcessObjectList))) {
        try {
            if (!property<UInt32>(process, kAudioProcessPropertyIsRunningOutput)) continue;
            NSString *bundle = CFBridgingRelease(property<CFStringRef>(process, kAudioProcessPropertyBundleID));
            if (![bundle isEqualToString:@"com.apple.Music"]) continue;
            const auto outputs = object_list(process, address(kAudioProcessPropertyDevices, kAudioObjectPropertyScopeOutput));
            if (std::find(outputs.begin(), outputs.end(), output) != outputs.end()) return true;
        } catch (const std::runtime_error &) {
            // The process can end while the HAL list is being read.
        }
    }
    return false;
}

OSStatus captured(AudioObjectID, const AudioTimeStamp *, const AudioBufferList *in, const AudioTimeStamp *time, AudioBufferList *,
                  const AudioTimeStamp *, void *context) {
    auto *c = static_cast<Capture *>(context);
    if (!in->mNumberBuffers) return noErr;
    const auto &first = in->mBuffers[0];
    const uint64_t host = host_ns(time->mHostTime) - c->latency_ns;
    if (in->mNumberBuffers == 1 && first.mNumberChannels == 2) {
        ba_engine_capture(c->slot, static_cast<const float *>(first.mData), first.mDataByteSize / 8, host);
        return noErr;
    }
    // Non-interleaved or mono: interleave into preallocated stereo frames.
    const UInt32 frames = std::min<UInt32>(first.mDataByteSize / sizeof(float) / std::max<UInt32>(first.mNumberChannels, 1), 8192);
    const float *left = static_cast<const float *>(first.mData);
    const float *right = in->mNumberBuffers > 1 ? static_cast<const float *>(in->mBuffers[1].mData) : left;
    const UInt32 stride = first.mNumberChannels ? first.mNumberChannels : 1;
    for (UInt32 i = 0; i < frames; ++i) {
        c->interleaved[i * 2] = left[i * stride];
        c->interleaved[i * 2 + 1] = in->mNumberBuffers > 1 ? right[i] : left[i * stride];
    }
    ba_engine_capture(c->slot, c->interleaved.data(), frames, host);
    return noErr;
}

// Engines start and stop while capturing (another Device on this Mac may begin
// playing): keep the tap's exclusions current. Rewrite the tap only when the
// set changes; a rewrite can restart its capture clock.
OSStatus processes_changed(AudioObjectID, UInt32, const AudioObjectPropertyAddress *, void *context) {
    auto *c = static_cast<Capture *>(context);
    if (c->tap == kAudioObjectUnknown) return noErr;
    @autoreleasepool {
        CATapDescription *description = CFBridgingRelease(property<CFTypeRef>(c->tap, kAudioTapPropertyDescription));
        NSArray<NSNumber *> *excluded = engine_processes();
        if (![[NSSet setWithArray:description.processes ?: @[]] isEqualToSet:[NSSet setWithArray:excluded]]) {
            description.processes = excluded;
            CFTypeRef raw = (__bridge CFTypeRef)description;
            auto a = address(kAudioTapPropertyDescription);
            AudioObjectSetPropertyData(c->tap, &a, 0, nullptr, sizeof(raw), &raw);
        }
    }
    return noErr;
}

class MacShell final : public ba::Shell {
    AudioComponentInstance output_ = nullptr;
    uint64_t output_latency_ns_ = 0;
    std::map<int, std::unique_ptr<Capture>> captures_;

    static OSStatus render(void *self, AudioUnitRenderActionFlags *, const AudioTimeStamp *time, UInt32, UInt32 frames,
                           AudioBufferList *data) {
        auto *shell = static_cast<MacShell *>(self);
        float *out = static_cast<float *>(data->mBuffers[0].mData);
        // The time stamp is when this buffer leaves the HAL; add the device's
        // own latency to get when its first frame reaches the speaker.
        ba_engine_render(out, frames, host_ns(time->mHostTime) + shell->output_latency_ns_);
        return noErr;
    }

    // The default input device. macOS asks the user once; a refusal is an error.
    static uint32_t start_microphone(Capture &c) {
        if ([AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio] == AVAuthorizationStatusNotDetermined) {
            dispatch_semaphore_t answered = dispatch_semaphore_create(0);
            [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio
                                     completionHandler:^(BOOL) { dispatch_semaphore_signal(answered); }];
            dispatch_semaphore_wait(answered, DISPATCH_TIME_FOREVER);
        }
        if ([AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio] != AVAuthorizationStatusAuthorized)
            throw std::runtime_error("microphone access denied; allow it in System Settings > Privacy & Security > Microphone");
        const AudioObjectID device = property<AudioObjectID>(kAudioObjectSystemObject, kAudioHardwarePropertyDefaultInputDevice);
        if (device == kAudioObjectUnknown) throw std::runtime_error("no default microphone");
        const auto format = property<AudioStreamBasicDescription>(device, kAudioDevicePropertyStreamFormat, kAudioObjectPropertyScopeInput);
        if (format.mFormatID != kAudioFormatLinearPCM || !(format.mFormatFlags & kAudioFormatFlagIsFloat) || format.mBitsPerChannel != 32)
            throw std::runtime_error("microphone is not float32");
        c.latency_ns = uint64_t(device_latency(device, kAudioObjectPropertyScopeInput) * 1e9 / format.mSampleRate);
        check(AudioDeviceCreateIOProcID(device, captured, &c, &c.io), "create microphone callback");
        c.device = device;
        check(AudioDeviceStart(device, c.io), "start microphone");
        return uint32_t(format.mSampleRate);
    }

    // Every process's output except our engines, through a private tap.
    static uint32_t start_system(Capture &c) {
        const AudioObjectID out = property<AudioObjectID>(kAudioObjectSystemObject, kAudioHardwarePropertyDefaultOutputDevice);
        c.tapped_output = out;
        NSString *uid = CFBridgingRelease(property<CFStringRef>(out, kAudioDevicePropertyDeviceUID));
        CATapDescription *description = [[CATapDescription alloc] initExcludingProcesses:engine_processes() andDeviceUID:uid withStream:0];
        description.name = @"BEAM Audio engine capture";
        description.privateTap = YES;
        description.muteBehavior = CATapUnmuted;
        check(AudioHardwareCreateProcessTap(description, &c.tap), "create system audio tap (needs System Audio Recording permission)");
        NSDictionary *composition = @{
            @kAudioAggregateDeviceNameKey : @"BEAM Audio engine capture",
            @kAudioAggregateDeviceUIDKey : NSUUID.UUID.UUIDString,
            @kAudioAggregateDeviceIsPrivateKey : @YES,
            @kAudioAggregateDeviceTapListKey : @[ @{@kAudioSubTapUIDKey : description.UUID.UUIDString} ],
            @kAudioAggregateDeviceTapAutoStartKey : @NO
        };
        check(AudioHardwareCreateAggregateDevice((__bridge CFDictionaryRef)composition, &c.aggregate), "create tap device");
        const auto format = property<AudioStreamBasicDescription>(c.tap, kAudioTapPropertyFormat);
        if (format.mFormatID != kAudioFormatLinearPCM || !(format.mFormatFlags & kAudioFormatFlagIsFloat) || format.mBitsPerChannel != 32)
            throw std::runtime_error("system tap is not float32");
        check(AudioDeviceCreateIOProcID(c.aggregate, captured, &c, &c.io), "create capture callback");
        c.device = c.aggregate;
        check(AudioDeviceStart(c.aggregate, c.io), "start system audio capture (check System Audio Recording permission)");
        auto processes = address(kAudioHardwarePropertyProcessObjectList);
        check(AudioObjectAddPropertyListener(kAudioObjectSystemObject, &processes, processes_changed, &c), "watch audio processes");
        return uint32_t(format.mSampleRate);
    }

    // 440 Hz at -12 dBFS in 10 ms blocks stamped on an ideal host clock: a
    // capture source with no device drift, for measurements.
    static uint32_t start_tone(Capture &c) {
        constexpr uint32_t rate = 48000, frames = 480;
        c.tone_running = true;
        c.tone = std::thread([&c] {
            const uint64_t start = ba::host_now_ns();
            std::vector<float> block(frames * 2);
            for (uint64_t n = 0; c.tone_running; n += frames) {
                for (uint32_t i = 0; i < frames; ++i)
                    block[i * 2] = block[i * 2 + 1] = 0.25f * float(std::sin(2 * M_PI * 440.0 * double(n + i) / rate));
                ba_engine_capture(c.slot, block.data(), frames, start + n * 1000000000ull / rate);
                const uint64_t next = start + (n + frames) * 1000000000ull / rate, now = ba::host_now_ns();
                if (next > now) std::this_thread::sleep_for(std::chrono::nanoseconds(next - now));
            }
        });
        return rate;
    }

    static void release(Capture &c) {
        if (c.tone_running.exchange(false)) c.tone.join();
        if (c.tap != kAudioObjectUnknown) {
            auto processes = address(kAudioHardwarePropertyProcessObjectList);
            AudioObjectRemovePropertyListener(kAudioObjectSystemObject, &processes, processes_changed, &c);
        }
        if (c.io) AudioDeviceStop(c.device, c.io), AudioDeviceDestroyIOProcID(c.device, c.io), c.io = nullptr;
        if (c.aggregate != kAudioObjectUnknown) AudioHardwareDestroyAggregateDevice(c.aggregate), c.aggregate = kAudioObjectUnknown;
        if (c.tap != kAudioObjectUnknown) AudioHardwareDestroyProcessTap(c.tap), c.tap = kAudioObjectUnknown;
    }

   public:
    uint32_t start_output() override {
        const AudioObjectID device = property<AudioObjectID>(kAudioObjectSystemObject, kAudioHardwarePropertyDefaultOutputDevice);
        if (device == kAudioObjectUnknown) throw std::runtime_error("no default output device");
        const double rate = property<Float64>(device, kAudioDevicePropertyNominalSampleRate);
        output_latency_ns_ = uint64_t(device_latency(device, kAudioObjectPropertyScopeOutput) * 1e9 / rate);
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

    uint32_t start_capture(int slot, const std::string &source) override {
        auto c = std::make_unique<Capture>();
        c->slot = slot;
        uint32_t rate = 0;
        try {
            if (source == "system") rate = start_system(*c);
            else if (source == "mic") rate = start_microphone(*c);
            else if (source == "tone") rate = start_tone(*c);
            else throw std::runtime_error("unsupported capture source " + source);
        } catch (...) {
            release(*c);
            throw;
        }
        captures_[slot] = std::move(c);
        return rate;
    }

    void stop_capture(int slot) override {
        auto it = captures_.find(slot);
        if (it == captures_.end()) return;
        release(*it->second);
        captures_.erase(it);
    }

    ba::json playback_step(const std::string &direction) override {
        @autoreleasepool {
            // Play/pause also works while paused; track steps need a playing track.
            const bool toggle = direction == "playpause";
            bool music_captured = false;
            for (const auto &[slot, capture] : captures_) {
                if (capture->tap != kAudioObjectUnknown && music_on_output(capture->tapped_output)) {
                    music_captured = true;
                    break;
                }
            }
            // Paused Music is not on any output, so resuming needs only a running broadcast.
            if (!music_captured && !(toggle && !captures_.empty())) return {{"status", "no_playable_track"}};

            // Only fixed AppleScript commands are used. Network text never
            // becomes AppleScript or an application identifier.
            NSString *command = toggle ? @"playpause" : direction == "next" ? @"next track" : @"previous track";
            NSString *source = [NSString stringWithFormat:
                @"if application \"/System/Applications/Music.app\" is not running then return {false, \"\"}\n"
                 "with timeout of 3 seconds\n"
                 "tell application \"/System/Applications/Music.app\"\n"
                 "%@"
                 "if class of current track is URL track then return {false, \"\"}\n"
                 "if duration of current track is less than or equal to 0 then return {false, \"\"}\n"
                 "%@\n"
                 "try\n"
                 "if player state is playing then return {true, name of current track}\n"
                 "end try\n"
                 "return {true, \"\"}\n"
                 "end tell\n"
                 "end timeout", toggle ? @"" : @"if player state is not playing then return {false, \"\"}\n", command];
            NSDictionary *error = nil;
            NSAppleEventDescriptor *result = [[[NSAppleScript alloc] initWithSource:source] executeAndReturnError:&error];
            if (!result) {
                const auto code = [error[NSAppleScriptErrorNumber] integerValue];
                return {{"status", code == -1743 || code == -1744 ? "automation_denied" : "unavailable"}};
            }
            if (![[result descriptorAtIndex:1] booleanValue]) return {{"status", "no_playable_track"}};
            ba::json response = {{"status", "done"}};
            NSData *track = [[[result descriptorAtIndex:2] stringValue] dataUsingEncoding:NSUTF8StringEncoding];
            if (track.length && track.length <= 512) {
                response["track"] = std::string(static_cast<const char *>(track.bytes), track.length);
            }
            return response;
        }
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
