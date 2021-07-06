//
//  LBH264Encoder.h
//  
//
//  Created by Nevyn Bengtsson on 2015-07-08.
//
//

#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <SPAsync/SPTask.h>
@protocol LBH264EncoderDelegate;

/**
	Takes sample buffers of uncompressed pixel data, and encodes to h264.
	@thread This class is thread-safe, and its methods can be called from any thread.
*/
@interface LBH264Encoder : NSObject
@property(nonatomic,weak) id<LBH264EncoderDelegate> delegate;
- (instancetype)initWithSize:(CGSize)size bitrate:(float)bitrate error:(NSError**)error;
- (void)encodeSampleBuffer:(CMSampleBufferRef)sampleBuffer forceKeyframe:(BOOL)forceKeyframe;
- (GFTask*)stop;
@end

@protocol LBH264EncoderDelegate <NSObject>
- (void)encoder:(LBH264Encoder*)encoder encodedSampleBuffer:(CMSampleBufferRef)sampleBuffer;
- (void)encoder:(LBH264Encoder*)encoder failedWithError:(NSError*)error;
@end
