//
//  LBAACEncoder.h
//  StreamTS
//
//  Created by nevyn Bengtsson on 13/05/15.
//  Copyright (c) 2015 nevyn Bengtsson. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
@class GFTask;
@protocol LBAACEncoderDelegate;

@interface LBAACEncoder : NSObject
- (id)initConvertingTo:(AudioStreamBasicDescription)toFormat;
@property(nonatomic,weak) id<LBAACEncoderDelegate> delegate;

// Starts automatically on first buffer
- (void)appendSampleBuffer:(CMSampleBufferRef)sampleBuffer;

- (GFTask *)stopEncoding;
@end

@protocol LBAACEncoderDelegate <NSObject>
- (void)encoder:(LBAACEncoder*)encoder encodedSampleBuffer:(CMSampleBufferRef)encodedSampleBuffer trimDurationAtStart:(int)trimDuration;
@end