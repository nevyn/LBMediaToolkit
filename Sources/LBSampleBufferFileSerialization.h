//
//  LBSampleBufferFileWriter.h
//
//  Created by nevyn Bengtsson on 2015-07-9.
//

#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
@protocol LBIFFWriter, LBIFFReader;

/**
    Writes a stream of CMSampleBuffers to disk, with presentation times, formats, etc.
    Will then be fed into a post processor that muxes an audio and video file into a single m4v file.
	@thread This class is not thread safe, and all calls are synchronous.
*/
@interface LBSampleBufferFileWriter : NSObject
- (instancetype)initWithDestination:(NSURL*)destination error:(NSError**)error;
- (instancetype)initWithWriter:(NSObject<LBIFFWriter>*)writer error:(NSError**)error;;
- (BOOL)writeSampleBuffer:(CMSampleBufferRef)sampleBuffer error:(NSError**)error;
- (void)close;
- (unsigned long long)offsetInFile;
@end


/**
    Reads a stream of CMSampleBuffers from disk, with presentation times, formats, etc.
	@thread This class is not thread safe, and all calls are synchronous.
*/
@interface LBSampleBufferFileReader : NSObject
- (instancetype)initWithSource:(NSURL*)source error:(NSError**)error;
- (instancetype)initWithReader:(NSObject<LBIFFReader>*)reader error:(NSError**)error;

- (CMSampleBufferRef)readSampleBuffer;
- (CMSampleBufferRef)peekSampleBuffer;
- (unsigned long long)offsetInFile;
- (BOOL)hasReachedEOF;
- (void)rewind;
@property(nonatomic,readonly) NSURL *source;
@property(nonatomic,readonly) CMSampleTimingInfo lastTimingInfo;
@end
