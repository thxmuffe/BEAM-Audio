// iPhone shell for the audio engine: RemoteIO output through the app's shared
// audio session (IOSAudioSession.swift). Capture is not available on iPhone
// yet. Owns OS audio only; the engine owns the samples.
#import <AVFAudio/AVFAudio.h>
#import <AudioToolbox/AudioToolbox.h>
#include <mach/mach_time.h>

#include <stdexcept>
#include <string>

#include "../../engine/engine.h"
#include "ba_audio_engine_ios.h"

// The app's audio session owner shares one OS session between bindings.
extern "C" void *ba_engine_audio_acquire(void);
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
void check(OSStatus status, const char *what) {
    if (status != noErr) throw std::runtime_error(std::string(what) + " (OSStatus " + std::to_string(status) + ")");
}

class IOSShell final : public ba::Shell {
    AudioComponentInstance output_ = nullptr;
    void *session_ = nullptr;
    uint64_t output_latency_ns_ = 0;

    static OSStatus render(void *self, AudioUnitRenderActionFlags *, const AudioTimeStamp *time, UInt32, UInt32 frames,
                           AudioBufferList *data) {
        auto *shell = static_cast<IOSShell *>(self);
        // The time stamp is when this buffer is handed to the hardware; the
        // session's output latency brings it to the speaker.
        ba_engine_render(static_cast<float *>(data->mBuffers[0].mData), frames,
                         host_ns(time->mHostTime) + shell->output_latency_ns_);
        return noErr;
    }

   public:
    uint32_t start_output() override {
        session_ = ba_engine_audio_acquire();
        if (!session_) throw std::runtime_error("audio session could not be activated");
        AVAudioSession *session = AVAudioSession.sharedInstance;
        const double rate = session.sampleRate;
        output_latency_ns_ = uint64_t(session.outputLatency * 1e9);
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

    uint32_t start_capture(const std::string &) override { throw std::runtime_error("capture is not available on iPhone yet"); }
    void stop_capture() override {}
};
}  // namespace

uint64_t ba::host_now_ns() { return host_ns(mach_absolute_time()); }

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
