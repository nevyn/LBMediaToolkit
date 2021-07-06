//
//  LBMediaTimeAdjuster.m
//
//  Created by nevyn Bengtsson on 2017-05-22.
//

#import "LBMediaTimeAdjuster.h"
#import "GFTimeSynchronizer.h"

CMSampleBufferRef LBCreateSampleBufferWithTime(CMSampleBufferRef sampleBuffer, CMTime pts)
{
    if(!sampleBuffer) {
        return NULL;
    }
    CMTime incomingPts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
    CMTime incomingDts = CMSampleBufferGetDecodeTimeStamp(sampleBuffer);
    CMTime dtsDiff = CMTimeSubtract(incomingPts, incomingDts);
    CMTime dts = CMTimeSubtract(pts, dtsDiff);

	CMItemCount count;
	OSStatus countInfoRetrieved = CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, 0, nil, &count);
	
	if(countInfoRetrieved != noErr) {
		GFLog(GFError, @"Warning: sample doesn't have timing info. Skipping sample");
		return NULL;
	}
	
	CMSampleTimingInfo *timingInfo = malloc(sizeof(CMSampleTimingInfo) * count);
	
	OSStatus timingInfoRetrieved = CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, count, timingInfo, &count);
	
	if(timingInfoRetrieved != noErr) {
		GFLog(GFError, @"Warning: sample doesn't have timing info. Skipping sample");
		free(timingInfo);
		return NULL;
	}
	
	for (CMItemCount idx = 0; idx < count; idx++) {
		timingInfo[idx].presentationTimeStamp = pts;
        if(CMTIME_IS_VALID(incomingDts) && CMTIME_IS_VALID(dts)) {
            timingInfo[idx].decodeTimeStamp = dts;
        }
	}
	
	CMSampleBufferRef adjustedSampleBuffer;
	OSStatus bufferCopied = CMSampleBufferCreateCopyWithNewTiming(kCFAllocatorDefault, sampleBuffer, count, timingInfo, &adjustedSampleBuffer);
	free(timingInfo);
	
	if(bufferCopied != noErr) {
		GFLog(GFError, @"Unable to copy camera video writer sample");
		return NULL;
	}
	
	return adjustedSampleBuffer;
}

@implementation LBMasterClockAdjuster
{
    CMTime _lastIncomingPts;
}
@synthesize lastSampleTime=_lastSampleTime;
- (void)start
{

}
- (CMSampleBufferRef)copyAdjustedSampleBuffer:(CMSampleBufferRef)sampleBuffer
{
    CMTime incomingPts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
    CMTime incomingPtsDeltaSinceLast = CMTimeSubtract(incomingPts, _lastIncomingPts);
    CMTime currentPts = [self.sync currentSynchronizedMediaTimeFromLast:_lastSampleTime withExpectedDelta:incomingPtsDeltaSinceLast];
    _lastIncomingPts = incomingPts;
    _lastSampleTime = currentPts;
    return LBCreateSampleBufferWithTime(sampleBuffer, currentPts);
}
@end


@implementation LBReferenceTimeAdjuster
{
	CMTime _referenceTime;
}
@synthesize lastSampleTime=_lastSampleTime;
- (void)start
{
    // Indicate that next frame is reference frame
    _referenceTime = kCMTimeInvalid;
}

- (CMSampleBufferRef)copyAdjustedSampleBuffer:(CMSampleBufferRef)sampleBuffer
{
    CMTime incomingPts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
    if(CMTIME_IS_INVALID(_referenceTime)) {
        _referenceTime = incomingPts;
    }
    CMTime currentPts = CMTimeSubtract(incomingPts, _referenceTime);
    _lastSampleTime = currentPts;
    return LBCreateSampleBufferWithTime(sampleBuffer, currentPts);
}
@end
