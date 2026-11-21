// iPhone shell for the audio engine: RemoteIO output and microphone input
// through the app's shared audio session (IOSAudioSession.swift). Other apps'
// audio ("system") comes only from a system broadcast: the broadcast upload
// extension writes it to a shared ring (ba_system_audio_ring.h) and a silent
// output unit here reads it on its real-time thread. That output also keeps the
// app running in the background while the person is in another app.
// Owns OS audio only; the engine owns the samples.
#import <AVFAudio/AVFAudio.h>
#import <AudioToolbox/AudioToolbox.h>
#include <mach/mach_time.h>

#include <algorithm>
#include <atomic>
#include <cstring>
#include <stdexcept>
#include <string>
#include <vector>

#include "../../engine/engine.h"
#include "ba_audio_engine_ios.h"
#include "ba_system_audio_ring.h"

// The app's audio session owner shares one OS session between bindings.
// mixing: other apps keep playing (needed while their audio is broadcast).
extern "C" void *ba_engine_audio_acquire(bool microphone, bool mixing);
extern "C" void ba_engine_audio_release(void *);

namespace {
uint64_t host_ns(uint64_t ticks) {
    static const mach_timebase_info_data_t base = [] {
        mach_timebase_info_data_t b;
        mach_timebase_info(&b);
        return b;
    }();
    return __uint128_t(ticks) * base.numer / base.denom;
}
// The ring the broadcast extension writes, mapped once from the app group.
ba_system_audio_ring *system_ring() {
    static ba_system_audio_ring *ring = [] () -> ba_system_audio_ring * {
        NSString *group = NSBundle.mainBundle.infoDictionary[@BA_SYSTEM_AUDIO_GROUP_KEY];
        NSURL *container = group ? [NSFileManager.defaultManager containerURLForSecurityApplicationGroupIdentifier:group] : nil;
        return container ? ba_system_audio_ring_map([container URLByAppendingPathComponent:@BA_SYSTEM_AUDIO_FILE].fileSystemRepresentation, 1)
                         : nullptr;
    }();
    return ring;
}
void check(OSStatus status, const char *what) {
    if (status != noErr) throw std::runtime_error(std::string(what) + " (OSStatus " + std::to_string(status) + ")");
}

class IOSShell final : public ba::Shell {
    AudioComponentInstance output_ = nullptr;
    void *session_ = nullptr;
    // Latencies follow the current route (speaker, Bluetooth, AirPlay, wired),
    // so a route change keeps playback on Session time; read on audio threads.
    std::atomic<uint64_t> output_latency_ns_{0}, input_latency_ns_{0};
    id route_observer_ = nil;
    NSOperationQueue *route_queue_ = nil;
    // Microphone: its own RemoteIO unit, input only.
    AudioComponentInstance input_ = nullptr;
    void *input_session_ = nullptr;
    int input_slot_ = -1;
    std::vector<float> mono_ = std::vector<float>(4096), stereo_ = std::vector<float>(8192);
    // System audio: a silent output unit whose callback pulls the ring.
    AudioComponentInstance pump_ = nullptr;
    void *pump_session_ = nullptr;
    int system_slot_ = -1;
    uint64_t read_ = 0;
    std::vector<float> system_ = std::vector<float>(8192);

    static OSStatus pump(void *self, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *, UInt32, UInt32,
                         AudioBufferList *data) {
        auto *shell = static_cast<IOSShell *>(self);
        for (UInt32 b = 0; b < data->mNumberBuffers; ++b) memset(data->mBuffers[b].mData, 0, data->mBuffers[b].mDataByteSize);
        *flags |= kAudioUnitRenderAction_OutputIsSilence;
        shell->pull();
        return noErr;
    }
    // Hands everything new in the ring to the engine, stamped with its capture
    // time. After a gap (or a broadcast restart) it resumes from the newest audio.
    void pull() {
        ba_system_audio_ring *ring = system_ring();
        if (!ring) return;
        const uint64_t written = BA_RING_LOAD(&ring->written);
        const uint64_t end_ns = BA_RING_LOAD(&ring->end_host_ns);
        const uint64_t limit = BA_SYSTEM_AUDIO_FRAMES / 2;
        if (read_ > written || written - read_ > limit) read_ = written > 2048 ? written - 2048 : 0;
        const size_t chunk = system_.size() / 2;
        while (read_ < written) {
            const uint32_t n = uint32_t(std::min<uint64_t>({written - read_, chunk, BA_SYSTEM_AUDIO_FRAMES - read_ % BA_SYSTEM_AUDIO_FRAMES}));
            memcpy(system_.data(), &ring->samples[(read_ % BA_SYSTEM_AUDIO_FRAMES) * 2], n * 2 * sizeof(float));
            const uint64_t host = end_ns - (written - read_) * 1000000000ull / BA_SYSTEM_AUDIO_RATE;
            ba_engine_capture(system_slot_, system_.data(), n, host);
            read_ += n;
        }
    }
    uint32_t start_system(int slot) {
        ba_system_audio_ring *ring = system_ring();
        if (!ring) throw std::runtime_error("system audio needs the OpenSound broadcast extension and its app group");
        if (!BA_RING_LOAD(&ring->running)) throw std::runtime_error("the screen broadcast is not running; tap ON AIR and choose Start Broadcast");
        if (pump_) throw std::runtime_error("system audio is already captured");
        system_slot_ = slot;
        read_ = BA_RING_LOAD(&ring->written);
        pump_session_ = ba_engine_audio_acquire(false, true);
        if (!pump_session_) throw std::runtime_error("audio session could not be activated");
        AudioComponentDescription d{kAudioUnitType_Output, kAudioUnitSubType_RemoteIO, kAudioUnitManufacturer_Apple, 0, 0};
        AudioComponent component = AudioComponentFindNext(nullptr, &d);
        if (!component) throw std::runtime_error("RemoteIO unavailable");
        check(AudioComponentInstanceNew(component, &pump_), "create system audio unit");
        AudioStreamBasicDescription f{};
        f.mSampleRate = AVAudioSession.sharedInstance.sampleRate, f.mFormatID = kAudioFormatLinearPCM;
        f.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
        f.mChannelsPerFrame = 2, f.mBitsPerChannel = 32, f.mFramesPerPacket = 1, f.mBytesPerFrame = 8, f.mBytesPerPacket = 8;
        check(AudioUnitSetProperty(pump_, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &f, sizeof(f)), "set system audio format");
        AURenderCallbackStruct callback{pump, this};
        check(AudioUnitSetProperty(pump_, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback, sizeof(callback)),
              "set system audio callback");
        check(AudioUnitInitialize(pump_), "initialize system audio unit");
        check(AudioOutputUnitStart(pump_), "start system audio");
        return BA_SYSTEM_AUDIO_RATE;
    }
    void stop_system() {
        if (pump_) {
            AudioOutputUnitStop(pump_);
            AudioUnitUninitialize(pump_);
            AudioComponentInstanceDispose(pump_);
            pump_ = nullptr;
        }
        if (pump_session_) ba_engine_audio_release(pump_session_), pump_session_ = nullptr;
        system_slot_ = -1;
        // Off air here ends the system broadcast as well.
        if (ba_system_audio_ring *ring = system_ring()) BA_RING_STORE(&ring->stop, 1u);
    }

    static OSStatus input_ready(void *self, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *time, UInt32, UInt32 frames,
                                AudioBufferList *) {
        auto *shell = static_cast<IOSShell *>(self);
        if (frames > shell->mono_.size()) return noErr;
        AudioBufferList list;
        list.mNumberBuffers = 1;
        list.mBuffers[0] = {1, UInt32(frames * sizeof(float)), shell->mono_.data()};
        if (AudioUnitRender(shell->input_, flags, time, 1, frames, &list) != noErr) return noErr;
        for (UInt32 i = 0; i < frames; ++i) shell->stereo_[i * 2] = shell->stereo_[i * 2 + 1] = shell->mono_[i];
        // The time stamp is when the buffer reached the unit; the session's
        // input latency puts it back at the microphone.
        ba_engine_capture(shell->input_slot_, shell->stereo_.data(), frames, host_ns(time->mHostTime) - shell->input_latency_ns_);
        return noErr;
    }

    static OSStatus render(void *self, AudioUnitRenderActionFlags *, const AudioTimeStamp *time, UInt32, UInt32 frames,
                           AudioBufferList *data) {
        auto *shell = static_cast<IOSShell *>(self);
        // The time stamp is when this buffer is handed to the hardware; the
        // session's output latency brings it to the speaker.
        ba_engine_render(static_cast<float *>(data->mBuffers[0].mData), frames,
                         host_ns(time->mHostTime) + shell->output_latency_ns_);
        return noErr;
    }

    void follow_route() {
        if (route_observer_) return;
        // Its own queue: never read the session on the thread that posts the
        // notification, which may be inside an activation on the control thread.
        route_queue_ = [NSOperationQueue new];
        route_queue_.maxConcurrentOperationCount = 1;
        route_observer_ = [NSNotificationCenter.defaultCenter addObserverForName:AVAudioSessionRouteChangeNotification
                                                                          object:nil
                                                                           queue:route_queue_
                                                                      usingBlock:^(NSNotification *) {
                                                                          AVAudioSession *s = AVAudioSession.sharedInstance;
                                                                          output_latency_ns_ = uint64_t(s.outputLatency * 1e9);
                                                                          input_latency_ns_ = uint64_t(s.inputLatency * 1e9);
                                                                      }];
    }

   public:
    uint32_t start_output() override {
        session_ = ba_engine_audio_acquire(false, false);
        if (!session_) throw std::runtime_error("audio session could not be activated");
        AVAudioSession *session = AVAudioSession.sharedInstance;
        const double rate = session.sampleRate;
        output_latency_ns_ = uint64_t(session.outputLatency * 1e9);
        follow_route();
        AudioComponentDescription d{kAudioUnitType_Output, kAudioUnitSubType_RemoteIO, kAudioUnitManufacturer_Apple, 0, 0};
        AudioComponent component = AudioComponentFindNext(nullptr, &d);
        if (!component) throw std::runtime_error("RemoteIO unavailable");
        check(AudioComponentInstanceNew(component, &output_), "create output unit");
        // The session rate, so the unit adds no hidden resampler of its own.
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
        if (output_) {
            AudioOutputUnitStop(output_);
            AudioUnitUninitialize(output_);
            AudioComponentInstanceDispose(output_);
            output_ = nullptr;
        }
        if (session_) ba_engine_audio_release(session_), session_ = nullptr;
    }

    uint32_t start_capture(int slot, const std::string &source) override {
        if (source == "system") return start_system(slot);
        if (source != "mic") throw std::runtime_error("only the microphone and system audio can be captured on iPhone");
        if (input_) throw std::runtime_error("the microphone is already captured");
        input_slot_ = slot;
        input_session_ = ba_engine_audio_acquire(true, false);
        if (!input_session_) throw std::runtime_error("microphone unavailable; allow OpenSound in Settings > Privacy & Security > Microphone");
        AVAudioSession *session = AVAudioSession.sharedInstance;
        const double rate = session.sampleRate;
        input_latency_ns_ = uint64_t(session.inputLatency * 1e9);
        follow_route();
        AudioComponentDescription d{kAudioUnitType_Output, kAudioUnitSubType_RemoteIO, kAudioUnitManufacturer_Apple, 0, 0};
        AudioComponent component = AudioComponentFindNext(nullptr, &d);
        if (!component) throw std::runtime_error("RemoteIO unavailable");
        check(AudioComponentInstanceNew(component, &input_), "create input unit");
        const UInt32 on = 1, off = 0;
        check(AudioUnitSetProperty(input_, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &on, sizeof(on)), "enable input");
        check(AudioUnitSetProperty(input_, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &off, sizeof(off)), "disable output");
        AudioStreamBasicDescription f{};
        f.mSampleRate = rate, f.mFormatID = kAudioFormatLinearPCM;
        f.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
        f.mChannelsPerFrame = 1, f.mBitsPerChannel = 32, f.mFramesPerPacket = 1, f.mBytesPerFrame = 4, f.mBytesPerPacket = 4;
        check(AudioUnitSetProperty(input_, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &f, sizeof(f)), "set input format");
        AURenderCallbackStruct callback{input_ready, this};
        check(AudioUnitSetProperty(input_, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &callback, sizeof(callback)),
              "set input callback");
        check(AudioUnitInitialize(input_), "initialize input unit");
        check(AudioOutputUnitStart(input_), "start microphone");
        return uint32_t(rate);
    }

    void stop_capture(int slot) override {
        if (slot == system_slot_) return stop_system();
        if (input_) {
            AudioOutputUnitStop(input_);
            AudioUnitUninitialize(input_);
            AudioComponentInstanceDispose(input_);
            input_ = nullptr;
        }
        if (input_session_) ba_engine_audio_release(input_session_), input_session_ = nullptr;
    }
};
}  // namespace

uint64_t ba::host_now_ns() { return host_ns(mach_absolute_time()); }

extern "C" bool ba_system_audio_running(void) {
    ba_system_audio_ring *ring = system_ring();
    return ring && BA_RING_LOAD(&ring->running);
}

extern "C" uint16_t ba_audio_engine_start(const char *crash_file) {
    static IOSShell shell;
    static uint16_t port = [crash_file] {
        try {
            return ba::serve_loopback(shell, crash_file);
        } catch (const std::exception &) {
            return uint16_t(0);
        }
    }();
    return port;
}
