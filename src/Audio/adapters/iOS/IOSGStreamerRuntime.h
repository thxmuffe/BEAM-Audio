#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
#ifdef __cplusplus
extern "C" {
#endif
// Static iOS SDK setup only. Media pipelines and their lifetime belong to the host.
BOOL ba_gstreamer_initialize(NSError * _Nullable * _Nullable error);
#ifdef __cplusplus
}
#endif
NS_ASSUME_NONNULL_END
