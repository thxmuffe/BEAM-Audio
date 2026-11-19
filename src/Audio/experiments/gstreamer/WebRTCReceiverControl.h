#import <Foundation/Foundation.h>

@class RTCRtpReceiver;

NS_ASSUME_NONNULL_BEGIN
#ifdef __cplusplus
extern "C" {
#endif
// nil restores NetEq's default; this does not guarantee an exact output time.
BOOL ba_webrtc_set_minimum_delay(RTCRtpReceiver *receiver, NSNumber *_Nullable seconds);
#ifdef __cplusplus
}
#endif
NS_ASSUME_NONNULL_END
