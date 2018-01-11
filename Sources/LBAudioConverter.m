//
//  LBAudioConverter.m
//  StreamTS
//
//  Created by nevyn Bengtsson on 13/05/15.
//  Copyright (c) 2015 nevyn Bengtsson. All rights reserved.
//

#import "LBAudioConverter.h"
#import <AudioToolbox/AudioToolbox.h>

#   define ConverterDebug(...)
//#	define ConverterDebug(...) NSLog(__VA_ARGS__)

@interface LBAudioConverterPacket : NSObject
@property(nonatomic) CMSampleBufferRef sampleBuffer;
@property(nonatomic,readonly) AudioBufferList *bufferList;
@property(nonatomic) UInt32 processedByteCount;
- (UInt32)remainingBytes;
@end

@interface LBAudioConverter ()
{
    AudioConverterRef _converter;
    AudioStreamBasicDescription _fromFormat;
    AudioStreamBasicDescription _toFormat;
	UInt32 _outputBitrate;
	
	BOOL _startOncePred;
	BOOL _running;
    
    void (^_stopCompletionBlock)(void);
	
	NSMutableArray *_queuedPackets;
	NSMutableSet *_packetsToDelete;
	NSCondition *_queueSemaphore;
    // only valid during ComplexFill
	CMTime _currentPresentationTime;
    AudioBufferList *_toBeConverted;
    size_t _offsetSoFar;
    AudioConverterPrimeInfo _primingInfo;
}
- (OSStatus)fillBuffer:(AudioBufferList*)ioData dataPacketCount:(UInt32*)ioNumberDataPackets packetDescription:(AudioStreamPacketDescription**)outDataPacketDescription;
@end

static OSStatus FillBufferTrampoline(AudioConverterRef               inAudioConverter,
                                        UInt32*                         ioNumberDataPackets,
                                        AudioBufferList*                ioData,
                                        AudioStreamPacketDescription**  outDataPacketDescription,
                                        void*                           inUserData)
{
    LBAudioConverter *converter = (__bridge LBAudioConverter*)inUserData;
    return [converter fillBuffer:ioData dataPacketCount:ioNumberDataPackets packetDescription:outDataPacketDescription];
}


@implementation LBAudioConverter
- (instancetype)initConvertingTo:(AudioStreamBasicDescription)toFormat
{
    if(!(self = [super init]))
        return nil;
	
    _toFormat = toFormat;
	_queuedPackets = [NSMutableArray new];
	_packetsToDelete = [NSMutableSet new];
    
    return self;
}

- (void)dealloc
{
    ConverterDebug(@"Deallocating audio converter %@ %p", self, _converter);
    AudioConverterDispose(_converter);
}

- (void)startEncoding
{
    OSStatus creationStatus = AudioConverterNew(&_fromFormat, &_toFormat, &_converter);
    if(creationStatus != noErr) {
        NSLog(@"Failed to create converter: %d", (int)creationStatus);
        return;
    }
	
    if(_toFormat.mFormatID == kAudioFormatMPEG4AAC) {
        _outputBitrate = 64000;
        OSStatus bitrateStatus = AudioConverterSetProperty(_converter, kAudioConverterEncodeBitRate, sizeof(_outputBitrate), &_outputBitrate);
        if(bitrateStatus != noErr) {
            NSLog(@"Failed to set bitrate: %d", (int)bitrateStatus);
            return;
        }
    } else {
        _outputBitrate = _toFormat.mSampleRate * _toFormat.mBitsPerChannel * _toFormat.mChannelsPerFrame;
    }

	_running = YES;
	
	_queueSemaphore = [[NSCondition alloc] init];
	[NSThread detachNewThreadSelector:@selector(_converterThread) toTarget:self withObject:nil];
}

- (void)stopEncoding:(void(^)(void))completion
{
    ConverterDebug(@"Audio converter asked to stop...");
    if(_stopCompletionBlock) {
        NSAssert(NO, @"Audio converter can't be to be stopped twice");
        return;
    }
    _stopCompletionBlock = completion;
	
	// Ensure self lives until the thread has been completely spun donw
	CFRetain((__bridge CFTypeRef)(self));
	
	[_queueSemaphore lock];
    if(_running) {
        _running = NO;
        [_queueSemaphore broadcast];
    } else {
        completion();
    }
	[_queueSemaphore unlock];
	
	// OK, we're potentially spun down and promise to not access any more ivars.
	CFRelease((__bridge CFTypeRef)(self));
}

- (void)appendSampleBuffer:(CMSampleBufferRef)sampleBuffer
{
	ConverterDebug(@"New sample buffer available, broadcasting");
	LBAudioConverterPacket *packet = [LBAudioConverterPacket new];
	packet.sampleBuffer = sampleBuffer;
	
	if(!_startOncePred) {
        _startOncePred = YES;
		CMAudioFormatDescriptionRef audioDesc = CMSampleBufferGetFormatDescription(sampleBuffer);
		const AudioStreamBasicDescription *inFormat = CMAudioFormatDescriptionGetStreamBasicDescription(audioDesc);
		ConverterDebug(@"Starting converter with source format %@", audioDesc);
		memcpy(&_fromFormat, inFormat, sizeof(_fromFormat));
		[self startEncoding];
	}
	
	[_queueSemaphore lock];
	[_queuedPackets addObject:packet];
	[_queueSemaphore broadcast];
	[_queueSemaphore unlock];
}

- (void)_converterThread
{
    ConverterDebug(@"Audio converter thread is starting");
    [NSThread currentThread].name = [NSString stringWithFormat:@"io.lookback.audioconverter.%p", self];
	while(_running) {
		@autoreleasepool {
			// Make quarter-second buffers.
			UInt32 bufferSize = (_outputBitrate/8) * 0.25;
			NSMutableData *outAudioBuffer = [NSMutableData dataWithLength:bufferSize];
			AudioBufferList outAudioBufferList;
			outAudioBufferList.mNumberBuffers = 1;
			outAudioBufferList.mBuffers[0].mNumberChannels = _toFormat.mChannelsPerFrame;
			outAudioBufferList.mBuffers[0].mDataByteSize = (UInt32)bufferSize;
			outAudioBufferList.mBuffers[0].mData = [outAudioBuffer mutableBytes];

            // figure out how many packets could fit in a quarter-second buffer
            UInt32 ioOutputDataPacketSize = 1;
            if(_toFormat.mFormatID != kAudioFormatMPEG4AAC) {
                UInt32 outputSizePerPacket = _toFormat.mBytesPerPacket;
                UInt32 size = sizeof(outputSizePerPacket);
                AudioConverterGetProperty(_converter, kAudioConverterPropertyMaximumOutputPacketSize, &size, &outputSizePerPacket);
                ioOutputDataPacketSize = bufferSize / outputSizePerPacket;
            }
            
			ConverterDebug(@"Converter is doing an iteration of %u output bytes (%u packets)", (unsigned int)bufferSize, (unsigned int)ioOutputDataPacketSize);
			
			_currentPresentationTime = kCMTimeInvalid;
			const OSStatus conversionResult = AudioConverterFillComplexBuffer(_converter, FillBufferTrampoline, (__bridge void*)self, &ioOutputDataPacketSize, &outAudioBufferList, NULL);
			[_packetsToDelete removeAllObjects];
		
			if(conversionResult != noErr) {
				NSLog(@"Failed to convert a buffer: %d", (int)conversionResult);
				continue;
			}
			if(outAudioBufferList.mBuffers[0].mDataByteSize == 0) {
				NSLog(@"No data generated, skipping buffer");
				continue;
			}

			UInt32 cookieSize = 0;
			AudioConverterGetPropertyInfo(_converter, kAudioConverterCompressionMagicCookie, &cookieSize, NULL);
			char cookie[cookieSize];
			AudioConverterGetProperty(_converter, kAudioConverterCompressionMagicCookie, &cookieSize, cookie);
			
			CMAudioFormatDescriptionRef audioFormat;
			const OSStatus formatCreationError = CMAudioFormatDescriptionCreate(
				kCFAllocatorDefault,
				&_toFormat,
				0, NULL, // layout
				cookieSize, cookie, // cookie
				NULL, // extensions
				&audioFormat);
			if(formatCreationError != noErr) {
				NSLog(@"Failed to convert a buffer because format creation failed: %d", (int)formatCreationError);
				continue;
			}
			CFAutorelease(audioFormat);
			CMSampleTimingInfo timing = {
				.duration = CMTimeMake(_toFormat.mFramesPerPacket, _toFormat.mSampleRate),
				.presentationTimeStamp = _currentPresentationTime,
				.decodeTimeStamp = _currentPresentationTime
			};
			
			size_t sampleSize =
				outAudioBufferList.mBuffers[0].mDataByteSize / ioOutputDataPacketSize;
			
			CMSampleBufferRef outSampleBuffer;
			OSStatus sampleBufferCreationStatus = CMSampleBufferCreate(
				NULL, // allocator
				NULL, // dataBuffer
				YES, // dataReady
				NULL, //makeDataReadyCallback
				NULL, //refcon for above
				audioFormat, // formatDescription
				ioOutputDataPacketSize,// numSamples
				1, // timingInfoCount
				&timing, // timingInfoArray
				1, // numSampleSizeEntries
				&sampleSize, // sampleSizeArray
				&outSampleBuffer
			);
			if(sampleBufferCreationStatus != noErr) {
				NSLog(@"Failed to create sample buffer: %d", (int)sampleBufferCreationStatus);
				continue;
			}
			
			OSStatus setDataBufferError = CMSampleBufferSetDataBufferFromAudioBufferList(outSampleBuffer, NULL, NULL, 0, &outAudioBufferList);
			if(setDataBufferError != noErr) {
				NSLog(@"Failed to set data buffer: %d", (int)setDataBufferError);
				continue;
			}
			
            if(_primingInfo.leadingFrames == 0) {
                UInt32 primingInfoSize = sizeof(_primingInfo);
                AudioConverterGetProperty(_converter, kAudioConverterPrimeInfo, &primingInfoSize, &_primingInfo);
            }
            
            /* Compared to an AVFoundation-generated buffer, these four attachments are missing, not sure if they are needed:
                com.apple.cmio.buffer_attachment.sequence_number(P) = 0
                com.apple.cmio.buffer_attachment.discontinuity_flags(P) = 131072
                com.apple.cmio.buffer_attachment.client_sequence_id(P) = 0x6100000298c0 : 6 : 0 : 2 : 3
                com.apple.cmio.buffer_attachment.audio.core_audio_audio_time_stamp(P) = <CFData 0x6000000e6d80 [0x7fff7487fed0]>{length = 64, capacity = 64, bytes = 0x000000d8e2ecac412bfb578d42090000 ... 0300000000000000}
            */
			
			ConverterDebug(@"Giving delegate %d output bytes of aac", outAudioBufferList.mBuffers[0].mDataByteSize);
			[self.delegate converter:self convertedSampleBuffer:outSampleBuffer trimDurationAtStart:_primingInfo.leadingFrames];
			CFRelease(outSampleBuffer);
		}
	}
    ConverterDebug(@"Audio conversion thread is exiting");
    _stopCompletionBlock();
}

- (OSStatus)fillBuffer:(AudioBufferList*)ioData dataPacketCount:(UInt32*)ioNumberDataPackets packetDescription:(AudioStreamPacketDescription**)outDataPacketDescription
{
	UInt32 requestedByteCount = *ioNumberDataPackets * _fromFormat.mBytesPerPacket;
	UInt32 bytesWrittenSoFar = 0;
	ConverterDebug(@"Got a request for %d input bytes", requestedByteCount);
	[_queueSemaphore lock];
	
	// The loop ensures we test predicates properly after the semaphore has signalled
	while (requestedByteCount - bytesWrittenSoFar > 0) {
		if(!_running) break;
		
		if(_queuedPackets.count == 0) {
			ConverterDebug(@"Waiting for data");
			[_queueSemaphore wait];
			continue;
		}
		
		ConverterDebug(@"Data is now available, %ld packets queued", (unsigned long)_queuedPackets.count);
		
		// Ok, we got data! Just fill in data from a single queued packet.
		LBAudioConverterPacket *first = [_queuedPackets firstObject];
		if(CMTIME_IS_INVALID(_currentPresentationTime)) {
			_currentPresentationTime = CMSampleBufferGetPresentationTimeStamp(first.sampleBuffer);
			// If we're starting from inside this buffer, advance the presentation time to match.
			if(first.processedByteCount > 0) {
				ConverterDebug(@"Bumping presentation time due to fetching in the middle of a buffer");
				_currentPresentationTime = CMTimeAdd(_currentPresentationTime, CMTimeMake(first.processedByteCount/_fromFormat.mBytesPerPacket, _fromFormat.mSampleRate));
			}
		}
		
		UInt32 bytesToWrite = MIN(requestedByteCount - bytesWrittenSoFar, first.remainingBytes);
		for(int i = 0; i < ioData->mNumberBuffers; i++) {
			ioData->mBuffers[i].mData = first.bufferList->mBuffers[i].mData + first.processedByteCount;
			ioData->mBuffers[i].mDataByteSize = bytesToWrite;
			ioData->mBuffers[i].mNumberChannels = first.bufferList->mBuffers[i].mNumberChannels;
		}
		first.processedByteCount += bytesToWrite;
		bytesWrittenSoFar += bytesToWrite;
		
		if(first.remainingBytes == 0) {
			[_packetsToDelete addObject:first];
			[_queuedPackets removeObjectAtIndex:0];
		}
		break;
	}
	
	[_queueSemaphore unlock];
	
	// if running is false, this will be 0, indicating EndOfStream
	*ioNumberDataPackets = bytesWrittenSoFar / _fromFormat.mBytesPerPacket;
	ConverterDebug(@"Fulfilled request with %d bytes", bytesWrittenSoFar);

    return noErr;
}

@end

@implementation LBAudioConverterPacket
{
	CMBlockBufferRef _blockBuffer;
}
- (void)setSampleBuffer:(CMSampleBufferRef)sampleBuffer
{
	if(sampleBuffer)
		CFRetain(sampleBuffer);
	if(_sampleBuffer)
		CFRelease(_sampleBuffer);
	_sampleBuffer = sampleBuffer;
	
	if(_sampleBuffer) {
		size_t bufferListSize;
		const OSStatus bufferSizeFetchError = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
			sampleBuffer,
			&bufferListSize, // bufferListSizeNeededOut
			NULL, // bufferListOut
			0, // size of the buffer list
			NULL, // allocator
			NULL, // allocator
			0, // flags
			NULL // buffer
		);
		if(bufferSizeFetchError != noErr) {
			NSLog(@"Failed to fetch buffer: %d", (int)bufferSizeFetchError);
			return;
		}

		_bufferList = malloc(bufferListSize);
		const OSStatus bufferFetchError = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
			sampleBuffer,
			NULL, // bufferListSizeNeededOut
			_bufferList, // bufferListOut
			bufferListSize, // size of the buffer list
			NULL,
			NULL,
			0,
			&_blockBuffer
		);
		if(bufferFetchError != noErr) {
			NSLog(@"Failed to fetch buffer: %d", (int)bufferFetchError);
			return;
		}
	} else {
		if(_blockBuffer) {
			CFRelease(_blockBuffer);
			_blockBuffer = NULL;
		}
		free(_bufferList);
		_bufferList = nil;
	}
}
- (void)dealloc
{
	self.sampleBuffer = NULL;
}
-(UInt32)remainingBytes
{
	return _bufferList->mBuffers[0].mDataByteSize - _processedByteCount;
}
@end
