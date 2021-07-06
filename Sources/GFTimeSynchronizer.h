#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import "GFClock.h"

/** Synchronizes time stamps for multiple event sources (video, screen, touches, ...) */
@interface GFTimeSynchronizer : NSObject
/** Given a time in real time, translate it into a CMTime offset into the current
    recording session. Any number of event sources can query this method.
    @return Offset into the session when the event happened.
*/
- (CMTime)currentSynchronizedMediaTime;

- (CMTime)currentSynchronizedMediaTimeInTimeScale:(CMTimeScale)timeScale;
/*!
    Like the above, but aims to give back sequential times even if they are not
    generated evenly. A use case would be an audio recorder that receives audio frames
    in chunks, rather than evenly. To avoid skipping frames, and to make playback even,
    this method can be used to get evenly distributed times.
    
    @param base  The last return value from this method. If `base + delta` is much bigger
                 than the current time, the current time will be returned to catch up with
                 real time.
    @param delta The interval expected between each invocation, i e the duration of the
                 content being timestamped.
 */
- (CMTime)currentSynchronizedMediaTimeFromLast:(CMTime)base withExpectedDelta:(CMTime)delta;

@property(nonatomic) GFClock *clock;
@end

@interface GFTimeSynchronizerMaster : GFTimeSynchronizer
/** For the master event source: decide what session time the current real time
    corresponds to. A sensible thing is to set this to '0' for 'now' when starting
    recording. Only a single event source should use this method, of course.
    @param mediaTime   The session time that the event source believes we're at
*/
- (void)setElapsedSynchronizedMediaTime:(CMTime)mediaTime;

- (BOOL)hasStarted;

- (void)pause;
- (void)resume;
@end
