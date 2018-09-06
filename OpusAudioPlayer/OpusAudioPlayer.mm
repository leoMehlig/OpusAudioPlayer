#import "OpusAudioPlayer.h"

#import "ASQueue.h"

#import "OpusAudioBuffer.h"

#import "opusfile.h"

#import <AudioUnit/AudioUnit.h>
#import <AudioToolbox/AudioToolbox.h>
#import <map>
#import <libkern/OSAtomic.h>
#import <os/lock.h>
#import <pthread.h>


#define kOutputBus 0
#define kInputBus 1



static const int TGOpusAudioPlayerBufferCount = 3;
static const int TGOpusAudioPlayerSampleRate = 48000; // libopusfile is bound to use 48 kHz

static std::map<intptr_t, __weak OpusAudioPlayer *> activeAudioPlayers;

static pthread_mutex_t filledBuffersLock = PTHREAD_MUTEX_INITIALIZER;

static os_unfair_lock audioPositionLock = OS_UNFAIR_LOCK_INIT;

@interface OpusAudioPlayer ()
{
@public
    intptr_t _playerId;
    
    NSString *_filePath;
    NSInteger _fileSize;
    
    int64_t _totalPcmDuration;
    
    bool _isPaused;
    
    OggOpusFile *_opusFile;
    AUGraph _graph;
    bool _audioGraphInitialized;
    
    OpusAudioBuffer *_filledAudioBuffers[TGOpusAudioPlayerBufferCount];
    int _filledAudioBufferCount;
    int _filledAudioBufferPosition;
    
    int64_t _currentPcmOffset;
    bool _finished;
}

@end

@implementation OpusAudioPlayer

+ (bool)canPlayFile:(NSString *)path
{
    int error = OPUS_OK;
    OggOpusFile *file = op_test_file([path UTF8String], &error);
    if (file != NULL)
    {
        error = op_test_open(file);
        op_free(file);
        
        return error == OPUS_OK;
    }
    return false;
}

+ (ASQueue *)_playerQueue
{
    static ASQueue *queue = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^
                  {
                      queue = [[ASQueue alloc] initWithName:"org.telegram.audioPlayerQueue"];
                  });

    return queue;
}

- (instancetype)initWithPath:(NSString *)path
{
    self = [super init];
    if (self != nil)
    {
        _filePath = path;

        static intptr_t nextPlayerId = 1;
        _playerId = nextPlayerId++;
        
        _isPaused = true;

        [[OpusAudioPlayer _playerQueue] dispatchOnQueue:^
        {
            self->_fileSize = [[[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil][NSFileSize] integerValue];
            if (self->_fileSize == 0)
            {
//                NSLog(@"[TGOpusAudioPlayer#%p invalid file]", self);
                [self cleanupAndReportError];
            }
        }];
    }
    return self;
}

- (void)dealloc
{
    [self cleanup];
}

- (void)cleanupAndReportError
{
    [self cleanup];
}

- (void)cleanup
{
    pthread_mutex_lock(&filledBuffersLock);
    activeAudioPlayers.erase(_playerId);
    
    for (int i = 0; i < TGOpusAudioPlayerBufferCount; i++)
    {
        if (_filledAudioBuffers[i] != NULL)
        {
            OpusAudioBufferDispose(_filledAudioBuffers[i]);
            _filledAudioBuffers[i] = NULL;
        }
    }
    _filledAudioBufferCount = 0;
    _filledAudioBufferPosition = 0;

    pthread_mutex_unlock(&filledBuffersLock);
    
    OggOpusFile *opusFile = _opusFile;
    _opusFile = NULL;


    AUGraph audioGraph = _graph;
    _graph = NULL;
    _audioGraphInitialized = false;
    
    intptr_t objectId = (intptr_t)self;
    
    [[OpusAudioPlayer _playerQueue] dispatchOnQueue:^
    {
        if (audioGraph != NULL)
        {
            OSStatus status = noErr;
            
            status = AUGraphStop(audioGraph);
            if (status != noErr)
                NSLog(@"[TGOpusAudioPlayer#%lx AUGraphStop failed: %d]", objectId, (int)status);
            
            status = AUGraphUninitialize(audioGraph);
            if (status != noErr)
                NSLog(@"[TGOpusAudioPlayer#%lx AUGraphUninitialize failed: %d]", objectId, (int)status);
            
            status = AUGraphClose(audioGraph);
            if (status != noErr)
                NSLog(@"[TGOpusAudioPlayer#%lx AUGraphClose failed: %d]", objectId, (int)status);
            
            status = DisposeAUGraph(audioGraph);
            if (status != noErr)
                NSLog(@"[TGOpusAudioPlayer#%lx DisposeAUGraph failed: %d]", objectId, (int)status);
        }
        
        if (opusFile != NULL)
            op_free(opusFile);
    }];
    
}

static OSStatus TGOpusAudioPlayerCallback(void *inRefCon, __unused AudioUnitRenderActionFlags *ioActionFlags, __unused const AudioTimeStamp *inTimeStamp, __unused UInt32 inBusNumber, __unused UInt32 inNumberFrames, AudioBufferList *ioData)
{
    intptr_t playerId = (intptr_t)inRefCon;
    
    pthread_mutex_lock(&filledBuffersLock);

    OpusAudioPlayer *self = nil;
    auto it = activeAudioPlayers.find(playerId);
    if (it != activeAudioPlayers.end())
        self = it->second;
    
    if (self != nil)
    {
        OpusAudioBuffer **freedAudioBuffers = NULL;
        int freedAudioBufferCount = 0;
        
        for (int i = 0; i < (int)ioData->mNumberBuffers; i++)
        {
            AudioBuffer *buffer = &ioData->mBuffers[i];
            
            buffer->mNumberChannels = 1;
            
            int requiredBytes = buffer->mDataByteSize;
            int writtenBytes = 0;
            
            while (self->_filledAudioBufferCount > 0 && writtenBytes < requiredBytes)
            {

                os_unfair_lock_lock(&audioPositionLock);
                self->_currentPcmOffset = self->_filledAudioBuffers[0]->pcmOffset + self->_filledAudioBufferPosition / 2;
                os_unfair_lock_unlock(&audioPositionLock);

                int takenBytes = MIN((int)self->_filledAudioBuffers[0]->size - self->_filledAudioBufferPosition, requiredBytes - writtenBytes);
                
                if (takenBytes != 0)
                {
                    memcpy(((uint8_t *)buffer->mData) + writtenBytes, self->_filledAudioBuffers[0]->data + self->_filledAudioBufferPosition, takenBytes);
                    writtenBytes += takenBytes;
                }
                
                if (self->_filledAudioBufferPosition + takenBytes >= (int)self->_filledAudioBuffers[0]->size)
                {
                    if (freedAudioBuffers == NULL)
                        freedAudioBuffers = (OpusAudioBuffer **)malloc(sizeof(OpusAudioBuffer *) * TGOpusAudioPlayerBufferCount);
                    freedAudioBuffers[freedAudioBufferCount] = self->_filledAudioBuffers[0];
                    freedAudioBufferCount++;
                    
                    for (int i = 0; i < TGOpusAudioPlayerBufferCount - 1; i++)
                    {
                        self->_filledAudioBuffers[i] = self->_filledAudioBuffers[i + 1];
                    }
                    self->_filledAudioBuffers[TGOpusAudioPlayerBufferCount - 1] = NULL;
                    
                    self->_filledAudioBufferCount--;
                    self->_filledAudioBufferPosition = 0;
                }
                else
                    self->_filledAudioBufferPosition += takenBytes;
            }
            
            if (writtenBytes < requiredBytes)
                memset(((uint8_t *)buffer->mData) + writtenBytes, 0, requiredBytes - writtenBytes);
        }
        
        if (freedAudioBufferCount != 0)
        {
            [[OpusAudioPlayer _playerQueue] dispatchOnQueue:^
            {
                for (int i = 0; i < freedAudioBufferCount; i++)
                {
                    [self fillBuffer:freedAudioBuffers[i]];
                }
                
                free(freedAudioBuffers);
            }];
        }
    }
    else
    {
        for (int i = 0; i < (int)ioData->mNumberBuffers; i++)
        {
            AudioBuffer *buffer = &ioData->mBuffers[i];
            buffer->mNumberChannels = 1;
            memset(buffer->mData, 0, buffer->mDataByteSize);
        }
    }
    
    pthread_mutex_unlock(&filledBuffersLock);

    return noErr;
}

- (bool)perform:(OSStatus)status error:(NSString *)error
{
    if (status == noErr) {
        return true;
    }
    else {
        NSLog(@"[TGOpusAudioPlayer#%@ %@ failed: %d]", self, error, (int)status);
        [self cleanupAndReportError];
        return false;
    }
}

- (void)play
{
    [self playFromPosition:-1.0];
}

- (void)playFromPosition:(NSTimeInterval)position
{
    [[OpusAudioPlayer _playerQueue] dispatchOnQueue:^
    {
        if (!self->_isPaused)
            return;
        
        if (self->_graph == NULL)
        {

            self->_isPaused = false;
            
            int openError = OPUS_OK;
            self->_opusFile = op_open_file([self->_filePath UTF8String], &openError);
            if (self->_opusFile == NULL || openError != OPUS_OK)
            {
                NSLog(@"[TGOpusAudioPlayer#%p op_open_file failed: %d]", self, openError);
                [self cleanupAndReportError];
                return;
            }
            
            self->_totalPcmDuration = op_pcm_total(self->_opusFile, -1);
            
            if (![self perform: NewAUGraph(&self->_graph) error:@"NewAUGraph"])
                return;
            
            AUNode converterNode;
            AudioComponentDescription converterDescription;
            converterDescription.componentType = kAudioUnitType_FormatConverter;
            converterDescription.componentSubType = kAudioUnitSubType_AUConverter;
            converterDescription.componentManufacturer = kAudioUnitManufacturer_Apple;
            if (![self perform: AUGraphAddNode(self->_graph, &converterDescription, &converterNode) error:@"AUGraphAddNode converter"])
                return;
            
            AUNode outputNode;
            AudioComponentDescription desc;
            desc.componentType = kAudioUnitType_Output;
            desc.componentSubType = kAudioUnitSubType_RemoteIO;
            desc.componentFlags = 0;
            desc.componentFlagsMask = 0;
            desc.componentManufacturer = kAudioUnitManufacturer_Apple;
            if (![self perform: AUGraphAddNode(self->_graph, &desc, &outputNode) error:@"AUGraphAddNode output"])
                return;

            if (![self perform: AUGraphOpen(self->_graph) error:@"AUGraphOpen"])
                return;
            
            if (![self perform: AUGraphConnectNodeInput(self->_graph, converterNode, 0, outputNode, 0) error:@"AUGraphConnectNodeInput converter"])
                return;


            AudioComponentInstance converterAudioUnit;
            if (![self perform: AUGraphNodeInfo(self->_graph, converterNode, &converterDescription, &converterAudioUnit) error:@"AUGraphNodeInfo converter"])
                return;
            
            AudioComponentInstance outputAudioUnit;
            if (![self perform: AUGraphNodeInfo(self->_graph, outputNode, &desc, &outputAudioUnit) error:@"AUGraphNodeInfo output"])
                return;
            
            AudioStreamBasicDescription outputAudioFormat;
            outputAudioFormat.mSampleRate = TGOpusAudioPlayerSampleRate;
            outputAudioFormat.mFormatID = kAudioFormatLinearPCM;
            outputAudioFormat.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
            outputAudioFormat.mFramesPerPacket = 1;
            outputAudioFormat.mChannelsPerFrame = 1;
            outputAudioFormat.mBitsPerChannel = 16;
            outputAudioFormat.mBytesPerPacket = 2;
            outputAudioFormat.mBytesPerFrame = 2;
            
            AudioUnitSetProperty(converterAudioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &outputAudioFormat, sizeof(outputAudioFormat));

            AURenderCallbackStruct callbackStruct;
            callbackStruct.inputProc = &TGOpusAudioPlayerCallback;
            callbackStruct.inputProcRefCon = (void *)self->_playerId;
            
            if (![self perform: AUGraphSetNodeInputCallback(self->_graph, converterNode, 0, &callbackStruct) error:@"AUGraphSetNodeInputCallback"])
                return;
            
            static const UInt32 one = 1;
            if (![self perform: AudioUnitSetProperty(outputAudioUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, kOutputBus, &one, sizeof(one)) error:@"AudioUnitSetProperty EnableIO"])
                return;
            
            if (![self perform: AUGraphInitialize(self->_graph) error:@"AUGraphInitialize"])
                return;
            
            pthread_mutex_lock(&filledBuffersLock);
            activeAudioPlayers[self->_playerId] = self;
            pthread_mutex_unlock(&filledBuffersLock);
            
            NSUInteger bufferByteSize = [self bufferByteSize];
            for (int i = 0; i < TGOpusAudioPlayerBufferCount; i++)
            {
                self->_filledAudioBuffers[i] = OpusAudioBufferWithCapacity(bufferByteSize);
            }
            self->_filledAudioBufferCount = TGOpusAudioPlayerBufferCount;
            self->_filledAudioBufferPosition = 0;
            
            self->_finished = false;
            
            if (![self perform: AUGraphStart(self->_graph) error:@"AUGraphStart"])
                return;
            
            self->_audioGraphInitialized = true;
        }
        else if (!self->_audioGraphInitialized) {


            self->_isPaused = false;
            
            self->_finished = false;
            
            pthread_mutex_lock(&filledBuffersLock);
            for (int i = 0; i < self->_filledAudioBufferCount; i++)
            {
                self->_filledAudioBuffers[i]->size = 0;
            }
            self->_filledAudioBufferPosition = 0;
            pthread_mutex_unlock(&filledBuffersLock);
            
            AUGraphStart(self->_graph);
            self->_audioGraphInitialized = true;
        }
        else
        {


            self->_isPaused = false;
            
            self->_finished = false;
            
            pthread_mutex_lock(&filledBuffersLock);
            for (int i = 0; i < self->_filledAudioBufferCount; i++)
            {
                self->_filledAudioBuffers[i]->size = 0;
            }
            self->_filledAudioBufferPosition = 0;
            pthread_mutex_unlock(&filledBuffersLock);
        }
    }];
}

- (void)fillBuffer:(OpusAudioBuffer *)audioBuffer
{
    if (_opusFile != NULL)
    {
        audioBuffer->pcmOffset = MAX(0, op_pcm_tell(_opusFile));
        
        if (!_isPaused)
        {
            if (_finished)
            {
                bool notifyFinished = false;
                pthread_mutex_lock(&filledBuffersLock);
                if (_filledAudioBufferCount == 0)
                    notifyFinished = true;
                pthread_mutex_unlock(&filledBuffersLock);
                
                return;
            }
            else
            {
                int availableOutputBytes = (int)audioBuffer->capacity;
                int writtenOutputBytes = 0;
                
                bool endOfFileReached = false;
                
                bool bufferPcmOffsetSet = false;
                
                while (writtenOutputBytes < availableOutputBytes)
                {
                    if (!bufferPcmOffsetSet)
                    {
                        bufferPcmOffsetSet = true;
                        audioBuffer->pcmOffset = MAX(0, op_pcm_tell(_opusFile));
                    }
                    
                    int readSamples = op_read(_opusFile, (opus_int16 *)(audioBuffer->data + writtenOutputBytes), (availableOutputBytes - writtenOutputBytes) / 2, NULL);
                    
                    if (readSamples > 0)
                        writtenOutputBytes += readSamples * 2;
                    else
                    {
                        if (readSamples < 0)
                            NSLog(@"[TGOpusAudioPlayer#%p op_read failed: %d]", self, readSamples);
                        
                        endOfFileReached = true;
                        
                        break;
                    }
                }
                
                audioBuffer->size = writtenOutputBytes;
                
                if (endOfFileReached)
                    _finished = true;
            }
        }
        else
        {
            memset(audioBuffer->data, 0, audioBuffer->capacity);
            audioBuffer->size = audioBuffer->capacity;
            audioBuffer->pcmOffset = _currentPcmOffset;
        }
    }
    else
    {
        memset(audioBuffer->data, 0, audioBuffer->capacity);
        audioBuffer->size = audioBuffer->capacity;
        audioBuffer->pcmOffset = _totalPcmDuration;
    }
    
    pthread_mutex_lock(&filledBuffersLock);
    _filledAudioBufferCount++;
    _filledAudioBuffers[_filledAudioBufferCount - 1] = audioBuffer;
    pthread_mutex_unlock(&filledBuffersLock);
}

- (NSUInteger)bufferByteSize
{
    static const NSUInteger maxBufferSize = 0x50000;
    static const NSUInteger minBufferSize = 0x4000;
    
    Float64 seconds = 0.4;
    
    Float64 numPacketsForTime = TGOpusAudioPlayerSampleRate * seconds;
    NSUInteger result = (NSUInteger)(numPacketsForTime * 2);
    
    return MAX(minBufferSize, MIN(maxBufferSize, result));
}

- (void)pause:(void (^)())completion
{
    [[OpusAudioPlayer _playerQueue] dispatchOnQueue:^
    {
        self->_isPaused = true;
        
        pthread_mutex_lock(&filledBuffersLock);
        for (int i = 0; i < self->_filledAudioBufferCount; i++)
        {
            if (self->_filledAudioBuffers[i]->size != 0)
                memset(_filledAudioBuffers[i]->data, 0, self->_filledAudioBuffers[i]->size);
            _filledAudioBuffers[i]->pcmOffset = self->_currentPcmOffset;
        }
        pthread_mutex_unlock(&filledBuffersLock);
        
        if (self->_audioGraphInitialized) {
            AUGraphStop(self->_graph);
            self->_audioGraphInitialized = false;
        }
        
        if (completion) {
            completion();
        }
    }];
}

- (void)stop
{
    [[OpusAudioPlayer _playerQueue] dispatchOnQueue:^
    {
        [self cleanup];
    }];
}

- (NSTimeInterval)currentPositionSync:(bool)sync
{
    __block NSTimeInterval result = 0.0;
    
    dispatch_block_t block = ^
    {
        os_unfair_lock_lock(&audioPositionLock);
        result = self->_currentPcmOffset / (NSTimeInterval)TGOpusAudioPlayerSampleRate;
        os_unfair_lock_unlock(&audioPositionLock);
    };
    
    if (sync)
        [[OpusAudioPlayer _playerQueue] dispatchOnQueue:block synchronous:true];
    else
        block();
    
    return result;
}

- (NSTimeInterval)duration
{
    return _totalPcmDuration / (NSTimeInterval)TGOpusAudioPlayerSampleRate;
}

@end
