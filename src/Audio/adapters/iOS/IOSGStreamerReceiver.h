#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
// Native media execution only; Erlang retains session and presentation policy.
@interface IOSGStreamerReceiver : NSObject
+ (BOOL)initializeEngine:(NSError * _Nullable * _Nullable)error;
- (instancetype)initWithEvents:(void (^)(NSDictionary *event))events;
- (void)handleCommand:(NSDictionary *)command;
- (void)close;
@end
NS_ASSUME_NONNULL_END
