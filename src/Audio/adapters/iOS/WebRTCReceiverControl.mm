#import <WebRTC/RTCRtpReceiver.h>
#import "WebRTCReceiverControl.h"
// Exact upstream private accessor + C++ interface for the pinned framework.
// No copied vtable declaration, object-layout access or patched dependency.
#import "RTCRtpReceiver+Private.h"
#include <cmath>
#include <optional>

BOOL ba_webrtc_set_minimum_delay(RTCRtpReceiver *receiver, NSNumber *seconds) {
    if (seconds && (!std::isfinite(seconds.doubleValue) || seconds.doubleValue < 0 ||
                    seconds.doubleValue > 10)) return NO;
    auto native = receiver.nativeRtpReceiver;
    if (!native || native->media_type() != webrtc::MediaType::AUDIO) return NO;
    native->SetJitterBufferMinimumDelay(seconds ? std::optional<double>(seconds.doubleValue) : std::nullopt);
    return YES;
}

// Bounded atomic mailbox: no locks, allocations or network calls on RemoteIO.
// Sequentially consistent atomics keep each accepted snapshot coherent.
#include <atomic>
#include <mach/mach_time.h>
struct ba_output_timing {
    std::atomic<uint64_t> sequence{0}, host{0}, observed{0};
    std::atomic<double> sample{0};
    std::atomic<uint32_t> flags{0}, frames{0};
    std::atomic<int32_t> status{0};
    mach_timebase_info_data_t timebase;
    ba_output_timing() { mach_timebase_info(&timebase); }
};
static_assert(std::atomic<uint64_t>::is_always_lock_free);
static_assert(std::atomic<double>::is_always_lock_free);
static_assert(std::atomic<uint32_t>::is_always_lock_free);
void *ba_output_timing_create(void) { return new ba_output_timing; }
void ba_output_timing_destroy(void *timing) { delete static_cast<ba_output_timing *>(timing); }
void ba_output_timing_record(void *timing, const AudioTimeStamp *timestamp,
                             UInt32 frames, OSStatus status) {
    auto &t = *static_cast<ba_output_timing *>(timing);
    t.sequence.fetch_add(1);
    t.host.store(timestamp->mHostTime);
    t.sample.store(timestamp->mSampleTime);
    t.flags.store(timestamp->mFlags);
    t.frames.store(frames);
    t.status.store(status);
    t.observed.store(mach_absolute_time());
    t.sequence.fetch_add(1);
}
NSDictionary<NSString *, id> *ba_output_timing_snapshot(void *timing) {
    auto &t = *static_cast<ba_output_timing *>(timing);
    for (int attempt = 0; attempt < 8; ++attempt) {
        auto before = t.sequence.load();
        if (!before || (before & 1)) continue;
        auto host = t.host.load(), observed = t.observed.load();
        auto sample = t.sample.load();
        auto flags = t.flags.load(), frames = t.frames.load();
        auto status = t.status.load();
        if (before != t.sequence.load()) continue;
        auto ns = [&](uint64_t ticks) -> uint64_t {
            return (uint64_t)((__uint128_t)ticks * t.timebase.numer / t.timebase.denom);
        };
        NSMutableDictionary *result = [@{
            @"outputRenderCallbackCount": @(before / 2),
            @"outputRenderObservedHostTimeNs": @(ns(observed)),
            @"outputTimingObservedHostTimeNs": @(ns(mach_absolute_time())),
            @"outputRenderFrames": @(frames), @"outputRenderStatus": @(status),
            @"outputRenderTimestampFlags": @(flags),
            @"outputRenderSampleRate": @48000,
            @"outputTimingBasis": @"remoteio_callback_uncompensated",
            @"outputSourceSampleMappingAvailable": @NO
        } mutableCopy];
        if (flags & kAudioTimeStampHostTimeValid) result[@"outputRenderHostTimeNs"] = @(ns(host));
        if ((flags & kAudioTimeStampSampleTimeValid) && std::isfinite(sample))
            result[@"outputRenderSampleTime"] = @(sample);
        return result;
    }
    return @{@"outputTimingStatus": @"waiting_for_render_callback"};
}
