#import "GFTimeSynchronizer.h"

@interface GFTimeSynchronizer ()
{
    @protected
    NSTimeInterval _startedAt;
	NSTimeInterval _pausedDuration;
	NSTimeInterval _pausedAt;
}
@end

@implementation GFTimeSynchronizer
- (instancetype)init
{
	if(!(self = [super init]))
		return nil;
	
	self.clock = [GFClock new];
	
	return self;
}

- (CMTime)currentSynchronizedMediaTime
{
    return [self currentSynchronizedMediaTimeInTimeScale:90000];
}

- (CMTime)currentSynchronizedMediaTimeInTimeScale:(CMTimeScale)timeScale
{
	@synchronized(self) { // for _pausedAt
		NSTimeInterval now = [_clock absoluteTime];
		CMTime ret;
    
        if(_startedAt == 0) {
            ret = CMTimeMake(0, 1);
        } else if(_pausedAt != 0) {
            ret = CMTimeMakeWithSeconds(_pausedAt - _startedAt, timeScale);
        } else {
            NSTimeInterval diff = now - _startedAt - _pausedDuration;
            ret = CMTimeMakeWithSeconds(diff, timeScale);
        }
        
		//NSLog(@"TIIIIME %02.2f (for %02.2f, started %02.2f) (paused duration %02.2f)", CMTimeGetSeconds(ret), now, _startedAt, _pausedDuration);
        LBGuardDescribe(CMTimeGetSeconds(ret) >= 0, @"Time must not be negative") else {
            return CMTimeMakeWithSeconds(0, timeScale);
        }
        
		return ret;
	}
}

- (CMTime)currentSynchronizedMediaTimeFromLast:(CMTime)base withExpectedDelta:(CMTime)delta
{
    CMTime calculatedTime = CMTimeAdd(base, delta);
    CMTime currentTime = [self currentSynchronizedMediaTime];
    CMTime diff = CMTimeAbsoluteValue(CMTimeSubtract(calculatedTime, currentTime));
    
    CMTime maximumAllowedDifference = CMTimeMakeWithSeconds(2, 90000); // CMTimeMultiply(delta, 10)
    // If there is too big of a difference to real time, return realtime instead of the calculation.
    if(CMTIME_IS_INVALID(base) || CMTimeCompare(diff, maximumAllowedDifference) > 0) {
        return currentTime;
    } else {
        return calculatedTime;
    }
}
@end

@implementation GFTimeSynchronizerMaster

- (BOOL)hasStarted
{
    @synchronized(self) {
        return _startedAt != 0;
    }
}

- (void)setElapsedSynchronizedMediaTime:(CMTime)mediaTime
{
    @synchronized(self) {
        NSTimeInterval now = [self.clock absoluteTime];
        NSTimeInterval oldPauseDuration = now - _pausedAt;
        _startedAt = now - CMTimeGetSeconds(mediaTime);
        
        // have to reset _pausedAt to be consistent with the new reference time
        if(_pausedAt) {
            _pausedAt = now - oldPauseDuration;
            // started must be before or equal to pausedAt
            _startedAt -= oldPauseDuration;
        }
        // and pausedDuration is no longer accurate with the new reference time, so zero it out
        _pausedDuration = 0;
    }
}

- (void)pause
{
    @synchronized(self) {
		if(_pausedAt != 0) {
			GFLog(GFError, @"Tried to pause paused timer");
			return;
		}
		
		_pausedAt = [self.clock absoluteTime];
	}
}

- (void)resume
{
	@synchronized(self) {
		if(_pausedAt == 0) {
			GFLog(GFError, @"Tried to resume non-paused timer");
			return;
		}
		NSTimeInterval resumedAt = [self.clock absoluteTime];
		NSTimeInterval thisPauseDuration = resumedAt - _pausedAt;
		GFLog(GFDebug, @"Unpausing: duration was %f, total is now %f", thisPauseDuration, _pausedDuration + thisPauseDuration);
		_pausedDuration += thisPauseDuration;
		_pausedAt = 0;
	}
}
@end
