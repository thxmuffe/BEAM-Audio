#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>

@class RTCRtpReceiver;

NS_ASSUME_NONNULL_BEGIN
#ifdef __cplusplus
extern "C" {
#endif
// nil restores NetEq's default; success means the native setter was called,
// not that an exact output time or effective buffer depth is guaranteed.
BOOL ba_webrtc_set_minimum_delay(RTCRtpReceiver *receiver, NSNumber *_Nullable seconds);
// One render-thread writer; snapshots allocate only on the control thread.
void *ba_output_timing_create(void);
void ba_output_timing_destroy(void *timing);
void ba_output_timing_record(void *timing, const AudioTimeStamp *timestamp,
                             UInt32 frames, OSStatus status);
NSDictionary<NSString *, id> *ba_output_timing_snapshot(void *timing);
#ifdef __cplusplus
}
#endif
NS_ASSUME_NONNULL_END
