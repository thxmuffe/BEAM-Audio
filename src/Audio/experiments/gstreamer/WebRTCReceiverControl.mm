#import <WebRTC/RTCRtpReceiver.h>
#import "WebRTCReceiverControl.h"
// Exact upstream accessor and interface for the pinned comparison framework.
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
