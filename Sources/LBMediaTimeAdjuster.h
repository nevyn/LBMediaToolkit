//
//  LBMediaTimeAdjuster.h
//
//  Created by nevyn Bengtsson on 2017-05-22.
//

#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
@class GFTimeSynchronizer;

/*!
    @protocol LBMediaTimeAdjuster
    
    Takes input sample buffers in wall clock/absolute times,
    and adjusts them to be in the time-space of the recording session.
*/
@protocol LBMediaTimeAdjuster <NSObject>
@required
@property(nonatomic,readonly) CMTime lastSampleTime;

- (CMSampleBufferRef)copyAdjustedSampleBuffer:(CMSampleBufferRef)sampleBuffer;
- (void)start;
@end

/// Uses a GFTimeSynchronizer to sync timestamps across all recorded inputs
@interface LBMasterClockAdjuster : NSObject <LBMediaTimeAdjuster>
@property(nonatomic) GFTimeSynchronizer *sync;
@end

/// For when frames are delivered in chunks and "now" is a bad time to use for
/// 
@interface LBReferenceTimeAdjuster : NSObject <LBMediaTimeAdjuster>

@end

CMSampleBufferRef LBCreateSampleBufferWithTime(CMSampleBufferRef sampleBuffer, CMTime pts);

