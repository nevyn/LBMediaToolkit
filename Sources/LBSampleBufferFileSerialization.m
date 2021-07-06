//
//  LBSampleBufferFileWriter.m
//
//  Created by nevyn Bengtsson on 2015-07-9.
//

#import "LBSampleBufferFileSerialization.h"
#import "LBIFFSerialization.h"
#import "GFFourCC.h"
#import "GFLogger.h"

CMTime CMTime_EndianNtoB(CMTime time) {
    return (CMTime){
        .value = EndianS64_NtoB(time.value),
        .timescale = EndianS32_NtoB(time.timescale),
        .flags = EndianU32_NtoB(time.flags),
        .epoch = EndianS64_NtoB(time.epoch),
    };
}
CMTime CMTime_EndianBtoN(CMTime time) {
    return (CMTime){
        .value = EndianS64_BtoN(time.value),
        .timescale = EndianS32_BtoN(time.timescale),
        .flags = EndianU32_BtoN(time.flags),
        .epoch = EndianS64_BtoN(time.epoch),
    };
}

static const uint32_t kFileFormatVersion = 1;

@implementation LBSampleBufferFileWriter
{
    NSObject<LBIFFWriter> *_writer;
	int32_t _bufferCount;
}
- (instancetype)initWithDestination:(NSURL*)destination error:(NSError**)error
{
    if(!(self = [super init]))
        return nil;
    
    NSError *writerError;
    NSObject<LBIFFWriter> *writer = [[LBIFFFileWriter alloc] initWithURL:destination error:&writerError];
    if(!writer) {
        if (error) {
            *error = writerError;
        }
        return nil;
    }
    
    return [self initWithWriter:writer error:error];
}

- (instancetype)initWithWriter:(NSObject<LBIFFWriter>*)writer error:(NSError**)error
{
    if(!(self = [super init])) {
        return nil;
    }
    
    _writer = writer;
    
    // header
    if(![_writer writeChunkType:'lbsb' uint32:kFileFormatVersion error:error])
        return nil;
    
    return self;
}

#define VTCheck(r) ({\
	err = (r);\
	if(err != noErr) {\
		GFLog(GFError, @"Failed " #r ": %d", (int)err);\
		if(error)\
			*error = [NSError errorWithDomain:@"io.lookback" code:1390 userInfo:@{\
				NSLocalizedDescriptionKey: @"Failed to write media data",\
				NSLocalizedFailureReasonErrorKey: [NSString stringWithFormat:@"Lookback cannot continue recording media to disk.\n\nDeveloper info: " #r @" failed with status code %d", (int)err]\
			}];\
		return NO;\
	}\
})
#define WriteCheck(r) ({\
	if(!(r)) {\
		GFLog(GFError, @"Failed " #r ": %@", error?*error:nil);\
		return NO;\
	}\
})

- (BOOL)writeSampleBuffer:(CMSampleBufferRef)sampleBuffer error:(NSError**)error
{
    OSStatus err;
    
    CMFormatDescriptionRef format = CMSampleBufferGetFormatDescription(sampleBuffer);
    CMItemCount sampleCount = CMSampleBufferGetNumSamples(sampleBuffer);
    CMItemCount timingInfosCount = 0;
        VTCheck(CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, 0, NULL, &timingInfosCount));
    CMSampleTimingInfo timingInfos[timingInfosCount];
        VTCheck(CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, timingInfosCount, timingInfos, NULL));
        for(int i = 0; i < timingInfosCount; i++) {
            timingInfos[i].decodeTimeStamp = CMTime_EndianNtoB(timingInfos[i].decodeTimeStamp);
            timingInfos[i].duration = CMTime_EndianNtoB(timingInfos[i].duration);
            timingInfos[i].presentationTimeStamp = CMTime_EndianNtoB(timingInfos[i].presentationTimeStamp);
        }

    CMItemCount sizesCount = 0;
        err = CMSampleBufferGetSampleSizeArray(sampleBuffer, 0, NULL, &sizesCount);
        if(err != kCMSampleBufferError_BufferHasNoSampleSizes) {
            VTCheck(err);
        }
    size_t sampleSizes[sizesCount];
        if(sizesCount > 0) {
            VTCheck(CMSampleBufferGetSampleSizeArray(sampleBuffer, sizesCount, sampleSizes, NULL));
        }
    
    // 1. Write header
    WriteCheck([_writer writeChunkType:'sbuf' uint32:CMFormatDescriptionGetMediaType(format) error:error]);
    
    // 2. Write formats
    if(CMFormatDescriptionGetMediaType(format) == kCMMediaType_Video) {
        if(CMFormatDescriptionGetMediaSubType(format) == 'avc1') {
            // block buffer/h264: create NALUs
            size_t parameterSetCount;
            int nalUnitLength = 0;
            VTCheck(CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, 0, NULL, NULL, &parameterSetCount, &nalUnitLength));
            WriteCheck([_writer writeChunkType:'nals' uint32:nalUnitLength error:error]);
            for(size_t i = 0; i < parameterSetCount; i++) {
                size_t parameterSetSize;
                const uint8_t *parameterSetData;
                VTCheck(CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, i, &parameterSetData, &parameterSetSize, NULL, NULL));
                WriteCheck([_writer writeChunkType:'vidf' data:[NSData dataWithBytesNoCopy:(void*)parameterSetData length:parameterSetSize freeWhenDone:NO] error:error]);
            }
        } else {
            // fmt will be implicit from image buffer
        }
    } else if(CMFormatDescriptionGetMediaType(format) == kCMMediaType_Audio) {
        CMBlockBufferRef formatBuffer;
        FourCharCode code = 'audf';
        OSStatus err = CMAudioFormatDescriptionCopyAsBigEndianSoundDescriptionBlockBuffer(NULL, format, kCMSoundDescriptionFlavor_ISOFamily, &formatBuffer);
        if(err == kCMFormatDescriptionBridgeError_IncompatibleFormatDescription) {
            err = CMAudioFormatDescriptionCopyAsBigEndianSoundDescriptionBlockBuffer(NULL, format, NULL, &formatBuffer); // QT format
            code = 'audq';
        }
        VTCheck(err);
        size_t length; char *data;
        VTCheck(CMBlockBufferGetDataPointer(formatBuffer, 0, NULL, &length, &data));
        WriteCheck([_writer writeChunkType:code data:[NSData dataWithBytesNoCopy:data length:length freeWhenDone:NO] error:error]);
        CFRelease(formatBuffer);
    } else {
        LBGuardDescribe(0, @"Can't handle this media type");
        return NO;
    }
    
    // 3. Write metadata
    WriteCheck([_writer writeChunkType:'smpc' uint32:(uint32_t)sampleCount error:error]);
    for(int i = 0; i < timingInfosCount; i++) {
        // note: not endian safe. Should be arch safe though (contains no arch-specific data sizes)
        WriteCheck([_writer writeChunkType:'time' data:[NSData dataWithBytesNoCopy:&timingInfos[i] length:sizeof(CMSampleTimingInfo) freeWhenDone:NO] error:error]);
    }
    for(int i = 0; i < sizesCount; i++) {
        WriteCheck([_writer writeChunkType:'sasz' uint32:(uint32_t)sampleSizes[i] error:error]);
    }
    
    // 4. Write  attachments
    NSArray *sampleAttachments = (id)CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, false);
    if(sampleAttachments) {
        NSError *err;
        NSData *d;
        if(!(d = [NSPropertyListSerialization dataWithPropertyList:sampleAttachments format:NSPropertyListBinaryFormat_v1_0 options:0 error:&err])) {
            GFLog(GFError, @"Unable to serialize sample attachments for sample buffer: %@", err);
            if(error) *error = err;
            return NO;
        }
        WriteCheck([_writer writeChunkType:'satc' data:d error:error]);
    }
    NSDictionary *nonPropagatingBufferAttachments = (id)CFBridgingRelease(CMCopyDictionaryOfAttachments(kCFAllocatorDefault, sampleBuffer, kCMAttachmentMode_ShouldNotPropagate));
    if(nonPropagatingBufferAttachments.count > 0) {
        NSError *err;
        NSData *d;
        if(!(d = [NSPropertyListSerialization dataWithPropertyList:nonPropagatingBufferAttachments format:NSPropertyListBinaryFormat_v1_0 options:0 error:&err])) {
            GFLog(GFError, @"Unable to serialize non-propagating buffer attachments for sample buffer: %@", err);
            if(error) *error = err;
            return NO;
        }
        WriteCheck([_writer writeChunkType:'batc' data:d error:error]);
    }
    NSMutableDictionary *propagatingBufferAttachments = [(id)CFBridgingRelease(CMCopyDictionaryOfAttachments(kCFAllocatorDefault, sampleBuffer, kCMAttachmentMode_ShouldPropagate)) mutableCopy];
    if(propagatingBufferAttachments.count > 0) {
        // can't serialize audio format descs, and don't need it.
        [propagatingBufferAttachments removeObjectForKey:@"com.apple.cmio.buffer_attachment.source_audio_format_description"];
        
        NSError *err;
        NSData *d;
        if(!(d = [NSPropertyListSerialization dataWithPropertyList:propagatingBufferAttachments format:NSPropertyListBinaryFormat_v1_0 options:0 error:&err])) {
            GFLog(GFError, @"Unable to serialize propagating buffer attachments for sample buffer: %@", err);
            if(error) *error = err;
            return NO;
        }
        WriteCheck([_writer writeChunkType:'batp' data:d error:error]);
    }
    
    
    // 5. Write payload!
    
    
    CMBlockBufferRef blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer);
    CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    
    if (blockBuffer) {
        size_t length = CMBlockBufferGetDataLength(blockBuffer);
        NSMutableData *data = [NSMutableData dataWithCapacity:length];
        char *dataPointer = NULL;
        size_t offset = 0;
        size_t lengthAtOffset;
        size_t totalLength;
        do {
            VTCheck(CMBlockBufferGetDataPointer(blockBuffer, offset, &lengthAtOffset, &totalLength, &dataPointer));
            [data appendBytes:dataPointer length:lengthAtOffset];
            offset += lengthAtOffset;
        } while(offset < totalLength);
        
        WriteCheck([_writer writeChunkType:'data' data:data error:error]);
    } else if(pixelBuffer) {
        if(!CVPixelBufferIsPlanar(pixelBuffer)) {
            NSData *linearPixels = [NSData
                dataWithBytesNoCopy:CVPixelBufferGetBaseAddress(pixelBuffer)
                length:CVPixelBufferGetDataSize(pixelBuffer)
                freeWhenDone:NO
            ];
            
            NSDictionary *pixelDesc = @{
                @"width": @(CVPixelBufferGetWidth(pixelBuffer)),
                @"height": @(CVPixelBufferGetHeight(pixelBuffer)),
                @"pixelFormatType": @(CVPixelBufferGetPixelFormatType(pixelBuffer)),
                @"bytesPerRow": @(CVPixelBufferGetBytesPerRow(pixelBuffer)),
                @"bytes": linearPixels,
            };
            
            NSError *err;
            NSData *serializedPixelDesc;
            if(!(serializedPixelDesc = [NSPropertyListSerialization dataWithPropertyList:pixelDesc format:NSPropertyListBinaryFormat_v1_0 options:0 error:&err])) {
                GFLog(GFError, @"Unable to serialize pixel desc for sample buffer: %@", err);
                if(error) *error = err;
                return NO;
            }
            WriteCheck([_writer writeChunkType:'pixl' data:serializedPixelDesc error:error]);
        } else {
            NSMutableData *contiguousPlanarPixels = [NSMutableData new];
            NSMutableArray *widths = [NSMutableArray new];
            NSMutableArray *heights = [NSMutableArray new];
            NSMutableArray *bprs = [NSMutableArray new];
            CVPixelBufferLockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
            for(size_t i = 0, c = CVPixelBufferGetPlaneCount(pixelBuffer); i < c; i++) {
                const uint8_t *planeBytes = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, i);
                size_t width = CVPixelBufferGetWidthOfPlane(pixelBuffer, i);
                size_t height = CVPixelBufferGetHeightOfPlane(pixelBuffer, i);
                size_t bpr = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, i);
                [widths addObject:@(width)];
                [heights addObject:@(height)];
                [bprs addObject:@(bpr)];
                size_t byteCount = bpr*height;
                [contiguousPlanarPixels appendBytes:planeBytes length:byteCount];
            }
            CVPixelBufferUnlockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
            
            NSDictionary *pixelDesc = @{
                @"countOfPlanes": @(CVPixelBufferGetPlaneCount(pixelBuffer)),
                @"width": @(CVPixelBufferGetWidth(pixelBuffer)),
                @"height": @(CVPixelBufferGetHeight(pixelBuffer)),
                @"widths": widths,
                @"heights": heights,
                @"bytesPerRows": bprs,
                @"pixelFormatType": @(CVPixelBufferGetPixelFormatType(pixelBuffer)),
                @"contiguousBytes": contiguousPlanarPixels,
            };
            
            NSError *err;
            NSData *serializedPixelDesc;
            if(!(serializedPixelDesc = [NSPropertyListSerialization dataWithPropertyList:pixelDesc format:NSPropertyListBinaryFormat_v1_0 options:0 error:&err])) {
                GFLog(GFError, @"Unable to serialize pixel desc for sample buffer: %@", err);
                if(error) *error = err;
                return NO;
            }
            
            // todo: write width, height, pixelFormatType, bytesPerRow
            WriteCheck([_writer writeChunkType:'pixp' data:serializedPixelDesc error:error]);
        }
    }
    
    [_writer synchronize];
    _bufferCount++;
    return YES;
}

- (void)close
{
	[_writer close];
    _writer = nil;
}

- (unsigned long long)offsetInFile
{
	return [_writer offset];
}

- (NSString*)description
{
	return [NSString stringWithFormat:@"<%@@%p over %@, %d buffer(s)>", [self class], self, _writer, _bufferCount];
}
@end

@implementation LBSampleBufferFileReader
{
    NSObject<LBIFFReader> *_reader;
    uint32_t _protocolVersion;
	int32_t _readCount;
}
- (instancetype)initWithSource:(NSURL*)source error:(NSError**)error
{
    LBIFFFileReader *reader = [[LBIFFFileReader alloc] initWithURL:source error:error];
    if(!reader) {
        return nil;
    }
    
    if(!(self = [self initWithReader:reader error:error])) {
        return nil;
    }
    return self;
}
- (instancetype)initWithReader:(NSObject<LBIFFReader>*)reader error:(NSError**)error
{
    if(!(self = [super init])) {
        return nil;
    }
    
    _reader = reader;
    
    // header
    LBIFFReadRequest *headerRequest = [_reader readChunk];
    _protocolVersion = headerRequest.uint32;
    if(!headerRequest || headerRequest.type != 'lbsb' || _protocolVersion != 1) {
        if(error) {
            *error = [NSError errorWithDomain:@"io.lookback" code:28934 userInfo:@{
                NSLocalizedDescriptionKey: @"Unable to read video file from disk",
                NSLocalizedFailureReasonErrorKey: [NSString stringWithFormat:@"The file %@ had an unexpected header %@.%d, and could not be read.", _source.path, GFFourCCString(headerRequest.type), _protocolVersion],
            }];
        }
        return nil;
    }
    
    return self;
}

- (CMSampleBufferRef)readSampleBuffer
{
    // required data to create a sample buffer
    NSData *blockBufferData = NULL;
    CMFormatDescriptionRef format = NULL;
    CMItemCount sampleCount = 0;
    CMItemCount timingInfosCount = 0;
    CMSampleTimingInfo *timingInfos = NULL;
    CMItemCount sampleSizesCount = 0;
    size_t *sampleSizes = NULL;
    NSArray *sampleAttachments = NULL;
    NSDictionary *nonPropagatingBufferAttachments = NULL;
    NSDictionary *propagatingBufferAttachments = NULL;
    NSDictionary *linearPixelDesc = NULL;
    NSDictionary *planarPixelDesc = NULL;
    BOOL foundHeader = NO;
    
    // intermediates
    uint32_t nalUnitLength = 0;
    NSMutableArray *parameterSetDatas = [NSMutableArray new];
    
    for(;;) {
        LBIFFReadRequest *chunk = [_reader readChunk];
        if(!chunk)
            break;
        if(chunk.type != 'sbuf' && foundHeader == NO) {
            GFLog(GFError, @"Skipping unexpected chunk type %@", GFFourCCString(chunk.type));
            continue;
        }
        switch (chunk.type) {
            case 'sbuf':{ // format header
                foundHeader = YES;
            } break;
            case 'nals':{
                nalUnitLength = chunk.uint32;
            } break;
            case 'vidf':{ // video format as h264 pps and sps (called once per ps)
                [parameterSetDatas addObject:chunk.data];
            } break;
            case 'audf':{ // audio format as ISO-MPEG SoundDescription
                OSStatus err = CMAudioFormatDescriptionCreateFromBigEndianSoundDescriptionData(NULL, chunk.data.bytes, chunk.data.length, kCMSoundDescriptionFlavor_ISOFamily, &format);
                if(err != noErr) {
                    GFLog(GFError, @"Failed to create ISO audio format from big endian description: %d", (int)err);
                    goto loopend;
                }
            } break;
            case 'audq':{ // audio format as QT SoundDescription
                OSStatus err = CMAudioFormatDescriptionCreateFromBigEndianSoundDescriptionData(NULL, chunk.data.bytes, chunk.data.length, NULL, &format);
                if(err != noErr) {
                    GFLog(GFError, @"Failed to create QT audio format from big endian description: %d", (int)err);
                    goto loopend;
                }
            } break;
            case 'smpc':{ // sample count
                sampleCount = chunk.uint32;
            } break;
            case 'time':{ // Timing info. May have multiple.
                if(sizeof(CMSampleTimingInfo) != chunk.data.length) {
                    GFLog(GFError, @"Unexpected chunk size");
                    timingInfosCount = 0;
                    goto loopend;
                }
                timingInfos = realloc(timingInfos, sizeof(CMSampleTimingInfo)*++timingInfosCount);
                [chunk.data getBytes:timingInfos+(timingInfosCount-1) length:sizeof(CMSampleTimingInfo)];
                timingInfos[timingInfosCount-1].decodeTimeStamp = CMTime_EndianBtoN(timingInfos[timingInfosCount-1].decodeTimeStamp);
                timingInfos[timingInfosCount-1].duration = CMTime_EndianBtoN(timingInfos[timingInfosCount-1].duration);
                timingInfos[timingInfosCount-1].presentationTimeStamp = CMTime_EndianBtoN(timingInfos[timingInfosCount-1].presentationTimeStamp);
                _lastTimingInfo = timingInfos[timingInfosCount-1];
            } break;
            case 'sasz':{ // Sample size. May have multiple.
                if(sizeof(uint32_t) != chunk.data.length) {
                    GFLog(GFError, @"Unexpected chunk size");
                    sampleSizesCount = 0;
                    goto loopend;
                }
                sampleSizes = realloc(sampleSizes, sizeof(size_t)*++sampleSizesCount);
                sampleSizes[sampleSizesCount-1] = chunk.uint32;
            } break;
            case 'satc':{
                NSError *err;
                sampleAttachments = [NSPropertyListSerialization propertyListWithData:chunk.data options:0 format:NULL error:&err];
                if(!sampleAttachments) {
                    GFLog(GFError, @"Couldn't deserialize sample buffer sample attachments: %@", err);
                    goto loopend;
                }
            } break;
            case 'batc':{
                NSError *err;
                nonPropagatingBufferAttachments = [NSPropertyListSerialization propertyListWithData:chunk.data options:0 format:NULL error:&err];
                if(!nonPropagatingBufferAttachments) {
                    GFLog(GFError, @"Couldn't deserialize sample buffer non-propagating buffer attachments: %@", err);
                }
            } break;
            case 'batp':{
                NSError *err;
                propagatingBufferAttachments = [NSPropertyListSerialization propertyListWithData:chunk.data options:0 format:NULL error:&err];
                if(!propagatingBufferAttachments) {
                    GFLog(GFError, @"Couldn't deserialize sample buffer propagating buffer attachments: %@", err);
                }
            } break;
            
            case 'pixl':{
                NSError *err;
                linearPixelDesc = [NSPropertyListSerialization propertyListWithData:chunk.data options:0 format:NULL error:&err];
                if(!linearPixelDesc) {
                    GFLog(GFError, @"Couldn't deserialize linear pixel data: %@", err);
                }
                goto loopend;
            } break;
            case 'pixp':{
                NSError *err;
                planarPixelDesc = [NSPropertyListSerialization propertyListWithData:chunk.data options:0 format:NULL error:&err];
                if(!planarPixelDesc) {
                    GFLog(GFError, @"Couldn't deserialize planar pixel data: %@", err);
                }
                goto loopend;
            } break;
            case 'data':{
                blockBufferData = chunk.data;
                // 'data' is always last; stop reading, we've got all the data for the sample buffer.
                goto loopend;
            } break;
            default: {
                GFLog(GFDebug, @"Warning: Skipping unrecognized chunk type %@", GFFourCCString(chunk.type));
            } break;
        }
    }
loopend:;
    
    if(nalUnitLength && parameterSetDatas.count > 0) {
        uint8_t *parameterSetPointers[parameterSetDatas.count];
        size_t sizes[parameterSetDatas.count];
        for(int i = 0; i < parameterSetDatas.count; i++) {
            parameterSetPointers[i] = (void*)[parameterSetDatas[i] bytes];
            sizes[i] = [parameterSetDatas[i] length];
        }
        OSStatus err = CMVideoFormatDescriptionCreateFromH264ParameterSets(NULL, parameterSetDatas.count, (void*)parameterSetPointers, sizes, nalUnitLength, &format);
        if(err != noErr) {
            GFLog(GFError, @"Failed to create video format from parameter sets: %d", (int)err);
        }
    }
    
    CMBlockBufferRef blockBuffer = NULL;
    CVPixelBufferRef imageBuffer = NULL;
    CMSampleBufferRef sampleBuffer = NULL;
    OSStatus err = 0;
    NSArray *attachmentsDestination = NULL;
    
    if(linearPixelDesc) {
        NSData *pixelData = linearPixelDesc[@"bytes"];
        err = CVPixelBufferCreateWithBytes(NULL,
            [linearPixelDesc[@"width"] integerValue], [linearPixelDesc[@"height"] integerValue],
            (OSType)[linearPixelDesc[@"pixelFormatType"] intValue],
            (void*)[pixelData bytes],
            [linearPixelDesc[@"bytesPerRow"] integerValue],
            (CVPixelBufferReleaseBytesCallback)CFRelease,
            (void*)CFBridgingRetain(pixelData),
            NULL,
            &imageBuffer
        );
    } else if(planarPixelDesc) {
        NSData *pixelData = planarPixelDesc[@"contiguousBytes"];
        size_t countOfPlanes = [planarPixelDesc[@"countOfPlanes"] integerValue];
        err = CVPixelBufferCreate(
            kCFAllocatorDefault, // allocator
            [planarPixelDesc[@"width"] integerValue], [planarPixelDesc[@"height"] integerValue],
            (OSType)[planarPixelDesc[@"pixelFormatType"] intValue],
            (__bridge CFDictionaryRef)@{
                (__bridge NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{}
            },
            &imageBuffer
        );
        CVPixelBufferLockBaseAddress(imageBuffer, 0);
        size_t srcOffset = 0;
        for(int i = 0; i < countOfPlanes; i++) {
            
            uint8_t *planeSrc = (uint8_t*)(pixelData.bytes + srcOffset);
            uint8_t *planeDest = CVPixelBufferGetBaseAddressOfPlane(imageBuffer, i);
            size_t destBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(imageBuffer, i);
            size_t srcBytesPerRow = [planarPixelDesc[@"bytesPerRows"][i] integerValue];
            size_t height = [planarPixelDesc[@"heights"][i] integerValue];
            
            for(int y = 0; y < height; y++) {
                memcpy(planeDest + y*destBytesPerRow, planeSrc + y*srcBytesPerRow, MIN(srcBytesPerRow,destBytesPerRow));
            }
            memset(planeDest, 0xff, CVPixelBufferGetBytesPerRowOfPlane(imageBuffer, i));

            srcOffset += srcBytesPerRow*height;
        }
        CVPixelBufferUnlockBaseAddress(imageBuffer, 0);
        
    } else if(blockBufferData) {
        // Block buffer wants ownership of the malloc'd data, so we can't use NSData's internal buffer; need to copy it over.
        void *mallocedData = malloc(blockBufferData.length);
        [blockBufferData getBytes:mallocedData length:blockBufferData.length];
        err = CMBlockBufferCreateWithMemoryBlock(NULL, mallocedData, blockBufferData.length, NULL, NULL, 0, blockBufferData.length, 0, &blockBuffer);

    // !! silence static analyzer. CMBlockBuffer assumes ownership of mallocedData, but clang-sa doesn't know, so it thinks this is a leak.
    #ifdef __clang_analyzer__
        free(mallocedData);
    #endif
    }
    
    if(err != noErr) {
        GFLog(GFError, @"Error when creating pixel or buffer from sample buffer file: %d", (int)err);
        goto cleanup;
    }
    
    if(imageBuffer) {
        err = CMVideoFormatDescriptionCreateForImageBuffer(NULL, imageBuffer, &format);
    }
    
    if(!(imageBuffer || blockBuffer) || !format || !sampleCount || !timingInfosCount || !timingInfos ) {
        GFLog(GFDebug, @"Reached end of file or parse error: %p %p %ld %ld %p %ld %p", blockBufferData, format, sampleCount, timingInfosCount, timingInfos, sampleSizesCount, sampleSizes);
        goto cleanup;
    }
    
    if(blockBuffer) {
        err = CMSampleBufferCreate(NULL, blockBuffer, YES, NULL, NULL, format, sampleCount, timingInfosCount, timingInfos, sampleSizesCount, sampleSizes, &sampleBuffer);
    } else if(imageBuffer) {
        err = CMSampleBufferCreateForImageBuffer(NULL, imageBuffer, YES, NULL, NULL, format, timingInfos, &sampleBuffer);
    }
    
    if(err != noErr) {
        GFLog(GFError, @"Error when creating sample buffer: %d", (int)err);
        goto cleanup;
    }
    
    if(sampleAttachments) {
        attachmentsDestination = (id)CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, true);
        int i = -1;
        for(NSDictionary *attachment in sampleAttachments) {
            i++;
            NSMutableDictionary *destAttachment = attachmentsDestination[i];
            for(id key in attachment) {
                destAttachment[key] = attachment[key];
            }
        }
    }
    
    if(nonPropagatingBufferAttachments)
        CMSetAttachments(sampleBuffer, (__bridge CFDictionaryRef)nonPropagatingBufferAttachments, kCMAttachmentMode_ShouldNotPropagate);
    if(propagatingBufferAttachments)
        CMSetAttachments(sampleBuffer, (__bridge CFDictionaryRef)propagatingBufferAttachments, kCMAttachmentMode_ShouldPropagate);
    
cleanup:
    if(blockBuffer)
        CFRelease(blockBuffer);
    if(imageBuffer)
        CFRelease(imageBuffer);
    if(format)
        CFRelease(format);
    free(sampleSizes);
    free(timingInfos);
    
    if(sampleBuffer) {
        _readCount++;
        return (CMSampleBufferRef)CFAutorelease(sampleBuffer);
    }
    return NULL;
}

- (CMSampleBufferRef)peekSampleBuffer
{
    CMSampleBufferRef ret = NULL;
    unsigned long long where = [_reader offset];
    ret = [self readSampleBuffer];
    if(ret) _readCount--;
    [_reader seekToOffset:where];
    return ret;
}

- (unsigned long long)offsetInFile
{
	return [_reader offset];
}

- (BOOL)hasReachedEOF
{
	return [_reader hasReachedEOF];
}

- (void)rewind
{
    [_reader seekToOffset:0];
    _readCount = 0;
}

- (NSString*)description
{
	return [NSString stringWithFormat:@"<%@@%p over %@; %d buffer(s)>", [self class], self, _reader, _readCount];
}
@end

