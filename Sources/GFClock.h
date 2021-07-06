#import <Foundation/Foundation.h>

@interface GFClock : NSObject
+ (instancetype)sharedClock;
// since device boot or something. Monotonically increasing, unaffected by date and time settings
- (NSTimeInterval)absoluteTime;

- (NSTimeInterval)machAbsoluteToTimeInterval:(uint64_t)machAbsolute;
@end
