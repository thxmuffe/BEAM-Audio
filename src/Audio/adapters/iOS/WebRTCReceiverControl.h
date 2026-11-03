#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>

@class RTCRtpReceiver;

NS_ASSUME_NONNULL_BEGIN
#ifdef __cplusplus
extern "C" {
#endif
// nil restores NetEq's default; success means the native setter was called,
// not that an exact output time or effective buffer depth is guaranteed.
BOOL ParviWebRTCSetMinimumDelay(RTCRtpReceiver *receiver, NSNumber *_Nullable seconds);
// One render-thread writer; snapshots allocate only on the control thread.
void *ParviOutputTimingCreate(void);
void ParviOutputTimingDestroy(void *timing);
void ParviOutputTimingRecord(void *timing, const AudioTimeStamp *timestamp,
                             UInt32 frames, OSStatus status);
NSDictionary<NSString *, id> *ParviOutputTimingSnapshot(void *timing);
#ifdef __cplusplus
}
#endif
NS_ASSUME_NONNULL_END
