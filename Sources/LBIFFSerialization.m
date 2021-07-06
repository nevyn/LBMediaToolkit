//
//  LBIFFSerialization.m
//
//  Created by nevyn Bengtsson on 2015-07-10.
//

#import "LBIFFSerialization.h"
#import "GFTargetConditionals.h"
#import "GFLogger.h"
#import "LBGuard.h"

#if GF_TARGET_OS_MAC_DESKTOP
#import <CoreServices/CoreServices.h> // for Endian.h
#else
#import <Endian.h>
#endif

@interface LBIFFReadRequest ()
- (instancetype)initWithType:(FourCharCode)type payload:(NSData*)payload;
@end


@implementation LBIFFFileWriter
{
	NSURL *_url;
    NSFileHandle *_handle;
}
- (instancetype)initWithURL:(NSURL*)URL error:(NSError *__autoreleasing *)error
{
    if(!(self = [super init])) {
        return nil;
    }
	_url = URL;
    [[NSFileManager defaultManager] createFileAtPath:URL.path contents:[NSData data] attributes:NULL];
	@try {
		_handle = [NSFileHandle fileHandleForWritingToURL:URL error:error];
		if(!_handle) {
			return nil;
        }
	} @catch (NSException *exception) {
		if(error) {
			*error = [NSError errorWithDomain:@"io.lookback" code:2803 userInfo:@{
				NSLocalizedDescriptionKey: @"Unable to write media file to disk",
				NSLocalizedFailureReasonErrorKey: [NSString stringWithFormat:
					@"While creating %@, we got the file system error %@, and cannot continue recording.",
					URL, [exception description]
				]
			}];
        }
		GFLog(GFError, @"Unable to create LBIFF file for serializing %@: %@", URL, exception);
		return nil;
	}
    return self;
}

- (BOOL)writeChunkType:(FourCharCode)type uint32:(uint32_t)payload error:(NSError *__autoreleasing *)error
{
    uint32_t converted = EndianU32_NtoB(payload);
    return [self writeChunkType:type data:[NSData dataWithBytesNoCopy:&converted length:sizeof(converted) freeWhenDone:NO] error:error];
}
- (BOOL)writeChunkType:(FourCharCode)type data:(NSData*)payload error:(NSError *__autoreleasing *)error
{
    LBGuardDescribe(payload.length < UINT32_MAX, @"Data too big for chunk");

    uint32_t convertedType = EndianU32_NtoB(type);
    uint32_t convertedLength = EndianU32_NtoB(payload.length);
	@try {
		[_handle writeData:[NSData dataWithBytesNoCopy:&convertedType length:sizeof(convertedType) freeWhenDone:NO]];
		[_handle writeData:[NSData dataWithBytesNoCopy:&convertedLength length:sizeof(convertedLength) freeWhenDone:NO]];
		[_handle writeData:payload];
	} @catch (NSException *exception) {
		if(error)
			*error = [NSError errorWithDomain:@"io.lookback" code:2804 userInfo:@{
				NSLocalizedDescriptionKey: @"Unable to write media data to file",
				NSLocalizedFailureReasonErrorKey: [NSString stringWithFormat:
					@"While writing to %@, we got the file system error %@, and cannot continue recording.",
					_url, [exception description]
				]
			}];
		return NO;
	}
	return YES;
}

- (NSString*)description
{
	return [NSString stringWithFormat:@"<%@@%p: %@ offs %lld>", [self class], self, _url.path, self.offset];
}

- (void)close
{
    @try {
        [_handle closeFile];
    } @catch (NSException *exception) {
        GFLog(GFError, @"Failed to close media file: %@ %@. Ignoring.", self, exception);
    }

}
- (void)synchronize
{
    @try {
        [_handle synchronizeFile];
    } @catch (NSException *exception) {
        GFLog(GFError, @"Failed to sync media file: %@ %@. Will try again on next sample buffer write.", self, exception);
    }
}
- (unsigned long long)offset
{
    @try {
        unsigned long long where = [_handle offsetInFile];
        return where;
    } @catch( NSException *exception) {
        GFLog(GFError, @"Failed to check offset in file due to file system error: %@ %@", self, exception);
        return 0;
    }
}

@end

@implementation LBIFFStreamWriter
{
    NSOutputStream *_stream;
}
- (instancetype)initWithOutputStream:(NSOutputStream*)stream
{
    if(!(self = [super init])) {
        return nil;
    }
    
    _stream = stream;
    
    return self;
}

- (void)_write:(NSData*)data
{
    NSUInteger totalWritten = 0;
    while(totalWritten < data.length) {
        const uint8_t *bytes = data.bytes;
        NSInteger written = [_stream write:bytes + totalWritten maxLength:data.length - totalWritten];
        LBGuard(written >= 0) else {
            GFLog(GFError, @"Failed to write bytes! %@", self);
            return;
        }
        totalWritten += written;
    }
}

- (BOOL)writeChunkType:(FourCharCode)type uint32:(uint32_t)payload error:(NSError *__autoreleasing *)error
{
    uint32_t converted = EndianU32_NtoB(payload);
    return [self writeChunkType:type data:[NSData dataWithBytesNoCopy:&converted length:sizeof(converted) freeWhenDone:NO] error:error];
}
- (BOOL)writeChunkType:(FourCharCode)type data:(NSData*)payload error:(NSError *__autoreleasing *)error
{
    LBGuardDescribe(payload.length < UINT32_MAX, @"Data too big for chunk");

    uint32_t convertedType = EndianU32_NtoB(type);
    uint32_t convertedLength = EndianU32_NtoB(payload.length);
    [self _write:[NSData dataWithBytesNoCopy:&convertedType length:sizeof(convertedType) freeWhenDone:NO]];
    [self _write:[NSData dataWithBytesNoCopy:&convertedLength length:sizeof(convertedLength) freeWhenDone:NO]];
    [self _write:payload];
	return YES;
}

- (void)close
{
    [_stream close];
}

- (void)synchronize
{
    return;
}

- (unsigned long long)offset
{
    return 0;
}

@end

#pragma mark - Reading

@implementation LBIFFFileReader
{
	NSURL *_url;
    NSFileHandle *_handle;
}
- (instancetype)initWithURL:(NSURL*)URL error:(NSError *__autoreleasing *)error
{
    if(!(self = [super init]))
        return nil;
	_url = URL;
	@try {
		_handle = [NSFileHandle fileHandleForReadingFromURL:URL error:error];
		if(!_handle)
			return nil;
	} @catch (NSException *exception) {
		if(error)
			*error = [NSError errorWithDomain:@"io.lookback" code:2803 userInfo:@{
				NSLocalizedDescriptionKey: @"Unable to read media file from disk",
				NSLocalizedFailureReasonErrorKey: [NSString stringWithFormat:
					@"While trying to read from %@, we got the error %@, and cannot continue reading.",
					URL, [exception description]
				]
			}];
		GFLog(GFError, @"Unable to open LBIFF file for reading %@: %@", URL, exception);
		return nil;
	}
    return self;
}

- (LBIFFReadRequest*)readChunk
{
	@try {
		NSData *headerData = [_handle readDataOfLength:8];
		if(headerData.length < 8)
			return nil;
		struct {
			FourCharCode type;
			uint32_t length;
		} header;
		[headerData getBytes:&header length:8];
		header.type = EndianU32_BtoN(header.type);
		header.length = EndianU32_BtoN(header.length);
		NSData *payload = [_handle readDataOfLength:header.length];
		if(payload.length < header.length)
			return nil;
		return [[LBIFFReadRequest alloc] initWithType:header.type payload:payload];
	} @catch (NSException *exception) {
		GFLog(GFError, @"Permanent LBIFF chunk read exception on %@: %@", self, exception);
		return nil;
	}
}
- (NSString*)description
{
	return [NSString stringWithFormat:@"<%@@%p: %@ offs %lld>", [self class], self, _url.path, self.offset];
}

- (unsigned long long)offset
{
    @try {
        unsigned long long where = [_handle offsetInFile];
        return where;
    } @catch( NSException *exception) {
        GFLog(GFError, @"Failed to check offset in file due to file system error: %@ %@", self, exception);
        return 0;
    }
}

- (void)seekToOffset:(unsigned long long)offset
{
    @try {
        [_handle seekToFileOffset:0];
    } @catch(NSException *exception) {
        GFLog(GFError, @"Failed to seek to %lld due to file system error: %@ %@", offset, self, exception);
    }
}

- (BOOL)hasReachedEOF
{
    @try {
        unsigned long long where = [_handle offsetInFile];
        [_handle seekToEndOfFile];
        if(_handle.offsetInFile == where)
              return YES;
        [_handle seekToFileOffset:where];
        return NO;
    } @catch( NSException *exception) {
        GFLog(GFError, @"Failed to check for EOF status due to file system error: %@ %@", self, exception);
        return YES;
    }
}
@end

@implementation LBIFFStreamReader
{
    NSInputStream *_stream;
}
- (instancetype)initWithInputStream:(NSInputStream*)stream
{
    if(!(self = [super init])) {
        return nil;
    }
    
    _stream = stream;
    
    return self;
}

- (NSData *)_readDataOfLength:(NSUInteger)length
{
    NSMutableData *outputBuffer = [NSMutableData dataWithLength:length];
    NSUInteger totalRead = 0;
    while(totalRead < length) {
        uint8_t *bufferPtr = (uint8_t*)outputBuffer.bytes;
        NSInteger bytesRead = [_stream read:bufferPtr + totalRead maxLength:length - totalRead];
        if(bytesRead > 0) {
            totalRead += bytesRead;
        } else if(bytesRead == 0 && totalRead == length) {
            break;
        } else if(bytesRead < 0) {
            GFLog(GFDebug, @"Failed to read, discarding");
            return nil;
        }
    }
    
    return outputBuffer;
}

- (LBIFFReadRequest*)readChunk
{
    NSData *headerData = [self _readDataOfLength:8];
    if(headerData.length < 8)
        return nil;
    struct {
        FourCharCode type;
        uint32_t length;
    } header;
    [headerData getBytes:&header length:8];
    header.type = EndianU32_BtoN(header.type);
    header.length = EndianU32_BtoN(header.length);
    NSData *payload = [self _readDataOfLength:header.length];
    if(payload.length < header.length)
        return nil;
    return [[LBIFFReadRequest alloc] initWithType:header.type payload:payload];
}

- (unsigned long long)offset
{
    return 0;
}
- (void)seekToOffset:(unsigned long long)offset
{
    return;
}
- (BOOL)hasReachedEOF
{
    return NO;
}



@end

@implementation LBIFFReadRequest
{
    FourCharCode _type;
    NSData *_payload;
}
- (instancetype)initWithType:(FourCharCode)type payload:(NSData*)payload
{
    if(!(self = [super init]))
        return nil;
    _type = type;
    _payload = payload;
    return self;
}
- (FourCharCode)type
{
    return _type;
}

- (uint32_t)uint32
{
    uint32_t payload;
    [_payload getBytes:&payload length:4];
    return EndianU32_BtoN(payload);
}

- (NSData*)data
{
    return _payload;
}
@end
