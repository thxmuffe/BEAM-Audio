#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
// Local control service. All media, including RTP and capture planes, stays native.
@interface BAGStreamerStreamHost : NSObject
- (uint16_t)start:(NSError **)error;
- (void)stop;
// Capture setup and callback data are consumed locally, never serialized to BEAM.
- (void)captureFormat:(const void *)metadata size:(uint32_t)size;
- (void)captureBlock:(const void *)block size:(uint32_t)size;
@end
NS_ASSUME_NONNULL_END
