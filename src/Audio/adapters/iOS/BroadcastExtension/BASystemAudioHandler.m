// Broadcast upload extension: iOS hands it the audio of other apps while the
// person runs a system broadcast (started from ON AIR or Control Center). It
// keeps only that audio, converts it with AVAudioConverter to the ring's fixed
// format and writes it to the shared ring for the app's audio engine. Screen
// video and the microphone track are dropped. Nothing leaves this process
// except through the ring.
#import <AVFAudio/AVFAudio.h>
#import <CoreMedia/CoreMedia.h>
#import <ReplayKit/ReplayKit.h>
#include <mach/mach_time.h>

#include "../ba_system_audio_ring.h"

static uint64_t host_now_ns(void) {
    static mach_timebase_info_data_t base;
    if (!base.denom) mach_timebase_info(&base);
    return (uint64_t)((__uint128_t)mach_absolute_time() * base.numer / base.denom);
}

static void post_changed(void) {
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         CFSTR(BA_SYSTEM_AUDIO_CHANGED), NULL, NULL, true);
}

@interface BASystemAudioHandler : RPBroadcastSampleHandler
@end

@implementation BASystemAudioHandler {
    ba_system_audio_ring *_ring;
    AVAudioFormat *_output;
    AVAudioConverter *_converter;
    AVAudioFormat *_input;
    AVAudioPCMBuffer *_converted;
}

- (void)broadcastStartedWithSetupInfo:(NSDictionary<NSString *, NSObject *> *)setupInfo {
    NSString *group = NSBundle.mainBundle.infoDictionary[@BA_SYSTEM_AUDIO_GROUP_KEY];
    NSURL *container = group ? [NSFileManager.defaultManager containerURLForSecurityApplicationGroupIdentifier:group] : nil;
    _ring = container ? ba_system_audio_ring_map([container URLByAppendingPathComponent:@BA_SYSTEM_AUDIO_FILE].fileSystemRepresentation, 1) : NULL;
    if (!_ring) {
        [self finishBroadcastWithError:[NSError errorWithDomain:@"OpenSound" code:1
            userInfo:@{NSLocalizedDescriptionKey: @"Could not reach OpenSound. Reinstall the app."}]];
        return;
    }
    _output = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32
                                               sampleRate:BA_SYSTEM_AUDIO_RATE channels:2 interleaved:YES];
    BA_RING_STORE(&_ring->stop, 0u);
    BA_RING_STORE(&_ring->heartbeat_ns, host_now_ns());
    BA_RING_STORE(&_ring->running, 1u);
    post_changed();
}

- (void)broadcastFinished {
    if (_ring) BA_RING_STORE(&_ring->running, 0u);
    post_changed();
}

- (void)processSampleBuffer:(CMSampleBufferRef)sampleBuffer withType:(RPSampleBufferType)type {
    if (!_ring) return;
    // OpenSound went off air: end the system broadcast too (iOS shows the reason).
    if (BA_RING_LOAD(&_ring->stop)) {
        BA_RING_STORE(&_ring->running, 0u);
        post_changed();
        [self finishBroadcastWithError:[NSError errorWithDomain:@"OpenSound" code:0
            userInfo:@{NSLocalizedDescriptionKey: @"OpenSound went off air."}]];
        return;
    }
    BA_RING_STORE(&_ring->heartbeat_ns, host_now_ns());
    if (type != RPSampleBufferTypeAudioApp) return;
    [self write:sampleBuffer];
}

- (void)write:(CMSampleBufferRef)sample {
    CMAudioFormatDescriptionRef description = CMSampleBufferGetFormatDescription(sample);
    const CMItemCount frames = CMSampleBufferGetNumSamples(sample);
    if (!description || frames <= 0) return;
    // A new input format (rate, channels, sample type) needs a new converter.
    if (!_input || !CMFormatDescriptionEqual(_input.formatDescription, description)) {
        _input = [[AVAudioFormat alloc] initWithCMAudioFormatDescription:description];
        _converter = _input ? [[AVAudioConverter alloc] initFromFormat:_input toFormat:_output] : nil;
    }
    if (!_converter) return;
    AVAudioPCMBuffer *in = [[AVAudioPCMBuffer alloc] initWithPCMFormat:_input frameCapacity:(AVAudioFrameCount)frames];
    if (!in || CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, 0, (int32_t)frames, in.mutableAudioBufferList) != noErr) return;
    in.frameLength = (AVAudioFrameCount)frames;

    const AVAudioFrameCount room = (AVAudioFrameCount)(frames * BA_SYSTEM_AUDIO_RATE / _input.sampleRate) + 64;
    if (!_converted || _converted.frameCapacity < room) _converted = [[AVAudioPCMBuffer alloc] initWithPCMFormat:_output frameCapacity:room];
    __block BOOL given = NO;
    NSError *error = nil;
    [_converter convertToBuffer:_converted error:&error withInputFromBlock:^AVAudioBuffer *(AVAudioPacketCount packets, AVAudioConverterInputStatus *status) {
        if (given) { *status = AVAudioConverterInputStatus_NoDataNow; return nil; }
        given = YES; *status = AVAudioConverterInputStatus_HaveData; return in;
    }];
    const uint32_t out = _converted.frameLength;
    if (error || !out) return;

    // Capture time: the buffer's presentation time is on the host clock.
    const CMTime pts = CMTimeConvertScale(CMSampleBufferGetPresentationTimeStamp(sample), 1000000000, kCMTimeRoundingMethod_Default);
    const uint64_t start_ns = pts.flags & kCMTimeFlags_Valid ? (uint64_t)pts.value : host_now_ns();
    const uint64_t end_ns = start_ns + (uint64_t)(frames * 1e9 / _input.sampleRate);

    const float *samples = _converted.floatChannelData[0];
    uint64_t written = _ring->written;
    for (uint32_t done = 0; done < out;) {
        const uint32_t at = (uint32_t)(written % BA_SYSTEM_AUDIO_FRAMES);
        const uint32_t n = MIN(out - done, BA_SYSTEM_AUDIO_FRAMES - at);
        memcpy(&_ring->samples[at * 2], &samples[done * 2], n * 2 * sizeof(float));
        done += n, written += n;
    }
    BA_RING_STORE(&_ring->end_host_ns, end_ns);
    BA_RING_STORE(&_ring->written, written);
}

@end
