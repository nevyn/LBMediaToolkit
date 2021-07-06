//
//  LBH264Encoder.m
//  
//
//  Created by Nevyn Bengtsson on 2015-07-08.
//
//

#import "LBH264Encoder.h"
#import <VideoToolbox/VideoToolbox.h>

@interface LBH264Encoder ()
{
    VTCompressionSessionRef _compressionSession;
	dispatch_queue_t _encoderQueue;
    int _consecutiveErrorCount;
    CMTime _lastIncomingPts;
}
- (void)didCompressWithStatus:(OSStatus)status flags:(VTEncodeInfoFlags)infoFlags samples:(CMSampleBufferRef)sampleBuffer;
@end

void compressionCallbackTrampoline(void *outputCallbackRefCon, void *sourceFrameRefCon, OSStatus status, VTEncodeInfoFlags infoFlags, CMSampleBufferRef sampleBuffer)
{
    LBH264Encoder *self = (__bridge id)outputCallbackRefCon;
    [self didCompressWithStatus:status flags:infoFlags samples:sampleBuffer];
}


@implementation LBH264Encoder
- (instancetype)initWithSize:(CGSize)size bitrate:(float)bitrate error:(NSError**)error
{
	if(!(self = [super init]))
		return nil;
	
	NSLog(@"Configuring compressor for pixel size %.0f,%.0f and bitrate %.0f", size.width, size.height, bitrate);
	
	_encoderQueue = dispatch_queue_create("io.lookback.h264.encoder", 0);
	
    OSStatus err;
    #define VTCheck(r) ({\
		err = (r);\
		if(err != noErr) {\
			NSLog(@"Failed " #r ": %d", (int)err);\
			if(error) \
				*error = [NSError errorWithDomain:@"io.lookback.videotoolbox" code:err userInfo:@{ \
				NSLocalizedDescriptionKey: @"Unable to compress video data", \
				NSLocalizedFailureReasonErrorKey: [NSString stringWithFormat:@"The compressor returned error %d", (int)err], \
			}]; \
			return nil;\
		}\
	})
	
	VTCheck(VTCompressionSessionCreate(
		NULL, // allocator
		size.width, size.height,
		kCMVideoCodecType_H264,
		(__bridge CFDictionaryRef)@{
			// Specifications
		},
		NULL,
		NULL,
		compressionCallbackTrampoline, (__bridge void*)self,
		&_compressionSession
	));
    VTCheck(VTSessionSetProperty(_compressionSession, kVTCompressionPropertyKey_AverageBitRate, (__bridge CFNumberRef)@(bitrate)));
	VTCheck(VTSessionSetProperty(_compressionSession, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue));
	
    return self;
}
- (void)dealloc
{
	if(_compressionSession)
		CFRelease(_compressionSession);
}

- (void)encodeSampleBuffer:(CMSampleBufferRef)sampleBuffer forceKeyframe:(BOOL)forceKeyframe
{
	CFRetain(sampleBuffer);
	dispatch_async(_encoderQueue, ^{
        
        CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
        CMTime presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
        CMTime duration = CMSampleBufferGetDuration(sampleBuffer);
        
        if(CMTIME_IS_VALID(_lastIncomingPts) && CMTimeCompare(presentationTime, _lastIncomingPts) < 1) {
            GFLog(GFError, @"Incoming non-incrementing PTS in encoder, dropping. Self %@ SB %@", self, sampleBuffer);
            CFRelease(sampleBuffer);
            return;
        }
        
		VTEncodeInfoFlags outFlags;
        OSStatus compressionStatus = VTCompressionSessionEncodeFrame(_compressionSession, imageBuffer, presentationTime, duration, (__bridge CFDictionaryRef)@{
			(NSString *)kVTEncodeFrameOptionKey_ForceKeyFrame: @(forceKeyframe)
		}, NULL, &outFlags);
        
		if(compressionStatus != noErr) {
			GFLog(GFError, @"Dropping sample due to a compression error: %d", (int)compressionStatus);
		}
		
		CFRelease(sampleBuffer);
	});
}

- (void)didCompressWithStatus:(OSStatus)status flags:(VTEncodeInfoFlags)infoFlags samples:(CMSampleBufferRef)sampleBuffer
{
    if(status != noErr) {
        _consecutiveErrorCount++;
        BOOL isFatalError = _consecutiveErrorCount > 10;
        GFLog(GFError, @"%@ failure while encoding H264: %d %d %@", isFatalError ? @"Fatal" : @"Temporary", (int)status, (unsigned int)infoFlags, sampleBuffer);
        if(isFatalError) {
            [self.delegate encoder:self failedWithError:[NSError errorWithDomain:@"com.apple.videotoolbox" code:status userInfo:@{
                NSLocalizedDescriptionKey: [NSString stringWithFormat:@"An unknown video encoding error %d occurred", (int)status],
            }]];
        }
    } else {
        _consecutiveErrorCount = 0;
        [self.delegate encoder:self encodedSampleBuffer:sampleBuffer];
    }
}

- (GFTask*)stop
{
    GFTaskCompletionSource *source = [[GFTaskCompletionSource alloc] init];
    
    dispatch_async(_encoderQueue, ^{
        VTCompressionSessionCompleteFrames(_compressionSession, kCMTimeInvalid);
        [source completeWithValue:nil];
    });
    return source.task;
}
@end
