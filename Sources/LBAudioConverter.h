//
//  LBAudioConverter.h
//  StreamTS
//
//  Created by nevyn Bengtsson on 13/05/15.
//  Copyright (c) 2015 nevyn Bengtsson. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
@protocol LBAudioConverterDelegate;

/*!
    @class LBAudioConverter
    @abstract Converts audio in real-time from one format to another
*/
@interface LBAudioConverter : NSObject
/*!
    @method initConvertingTo:
    @param toFormat The audio format you wish to convert your audio into.
    @discussion The "fromFormat" will be inferred from the first sample buffer you send in.
*/
- (instancetype)initConvertingTo:(AudioStreamBasicDescription)toFormat;
@property(nonatomic,weak) id<LBAudioConverterDelegate> delegate;

/*!
    @method appendSampleBuffer:
    @abstract Request that the audio in this sample buffer is converted to the destination format.
    @discussion If this is the first sample buffer being sent in,
        * The encoder thread will now be kicked off and the conversion started. After this call,
          you need to eventually call `stopEncoding:`.
        * The source format will be derived from the audio in `sampleBuffer`. If you later send in
          audio in some other format, this is an error and the audio will be silently discarded.
*/
- (void)appendSampleBuffer:(CMSampleBufferRef)sampleBuffer;

/*!
    @method stopEncoding:
    @abstract   Flushes the conversion pipeline, kills the conversion thread, and finishes
                the conversion process.
 
    @discussion Since conversion is done on a separate thread, it cannot finish immediately.
                This call will request the other thread to process all queued audio,
                then terminate the thread, and then call the completion block.
    @param completion   This block will be invoked once the thread is ready to terminate and
                        all audio has been converted. It might be called synchronously on the
                        calling thread, or asynchronously on the audio conversion thread.
*/
- (void)stopEncoding:(void(^)(void))completion;
@end

@protocol LBAudioConverterDelegate <NSObject>
/*!
    @method converter:convertedSampleBuffer:trimDurationAtStart:
    @abstract   Audio has been converted and is being provided to you in the requested format.
 
    @discussion Called on the internal audio thread. Any work you do in this delegate method
                will block further conversion, so dispatch to another thread if you're doing
                long running work.
 
    @param converter             The converter performing the conversion
    @param convertedSampleBuffer A sample buffer in the destination `toFormat` with a +0 retain count.
                                 Retain it if you wish to use it.
    @param trimDuration          If the destination format is AAC, this is the built-in "encoder delay"
                                 or "leading frames" that you need to write to the audio track's header
                                 when you mux.
*/
- (void)converter:(LBAudioConverter*)converter convertedSampleBuffer:(CMSampleBufferRef)convertedSampleBuffer trimDurationAtStart:(int)trimDuration;
@end
