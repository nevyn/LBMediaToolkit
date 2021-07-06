//
//  LBIFFSerialization.h
//
//  Created by nevyn Bengtsson on 2015-07-10.
//

#import <Foundation/Foundation.h>
@class LBIFFReadRequest;

// ---- Writing ----

@protocol LBIFFWriter <NSObject>
- (BOOL)writeChunkType:(FourCharCode)type uint32:(uint32_t)payload error:(NSError *__autoreleasing *)error;
- (BOOL)writeChunkType:(FourCharCode)type data:(NSData*)payload error:(NSError *__autoreleasing *)error;

- (void)close;
- (void)synchronize;
- (unsigned long long)offset;
@end

@interface LBIFFFileWriter : NSObject <LBIFFWriter>
- (instancetype)initWithURL:(NSURL*)URL error:(NSError *__autoreleasing *)error;

@property(nonatomic,readonly) NSURL *url;
@end

@interface LBIFFStreamWriter : NSObject <LBIFFWriter>
- (instancetype)initWithOutputStream:(NSOutputStream*)stream;
@end

// ---- Reading ----
@protocol LBIFFReader <NSObject>
- (LBIFFReadRequest*)readChunk;

- (unsigned long long)offset;
- (void)seekToOffset:(unsigned long long)offset;
- (BOOL)hasReachedEOF;
@end

@interface LBIFFFileReader : NSObject <LBIFFReader>
- (instancetype)initWithURL:(NSURL*)URL error:(NSError *__autoreleasing *)error;
@end

@interface LBIFFStreamReader : NSObject <LBIFFReader>
- (instancetype)initWithInputStream:(NSInputStream*)stream;
@end

@interface LBIFFReadRequest : NSObject
- (FourCharCode)type;

// union: read one of these
- (uint32_t)uint32;
- (NSData*)data;
@end
