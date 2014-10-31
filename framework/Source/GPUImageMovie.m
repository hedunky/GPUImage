#import "GPUImageMovie.h"
#import "GPUImageMovieWriter.h"
#import "GPUImageFilter.h"
#import "GPUImageVideoCamera.h"

@interface GPUImageMovie () <AVPlayerItemOutputPullDelegate>
{
    const GLfloat *_preferredConversion;
}

@property (nonatomic, assign) BOOL audioEncodingIsFinished;
@property (nonatomic, assign) BOOL videoEncodingIsFinished;
@property (nonatomic, strong) GPUImageMovieWriter *synchronizedMovieWriter;

@property (nonatomic, strong) AVAssetReader *reader;
@property (nonatomic, strong) AVPlayerItemVideoOutput *playerItemOutput;
@property (nonatomic, strong) CADisplayLink *displayLink;

@property (nonatomic, assign) CMTime previousFrameTime;
@property (nonatomic, assign) CMTime processingFrameTime;
@property (nonatomic, assign) CFAbsoluteTime previousActualFrameTime;
@property (nonatomic, assign) BOOL keepLooping;

@property (nonatomic, assign) GLuint luminanceTexture;
@property (nonatomic, assign) GLuint chrominanceTexture;
@property (nonatomic, strong) GLProgram *yuvConversionProgram;

@property (nonatomic, assign) GLint yuvConversionPositionAttribute;
@property (nonatomic, assign) GLint yuvConversionTextureCoordinateAttribute;
@property (nonatomic, assign) GLint yuvConversionLuminanceTextureUniform;
@property (nonatomic, assign) GLint yuvConversionChrominanceTextureUniform;
@property (nonatomic, assign) GLint yuvConversionMatrixUniform;

@property (nonatomic, assign) BOOL isFullYUVRange;
@property (nonatomic, assign) int imageBufferWidth;
@property (nonatomic, assign) int imageBufferHeight;

@property (nonatomic, strong) AVAudioPlayer *audioPlayer;
@property (nonatomic, assign) CFAbsoluteTime startActualFrameTime;
@property (nonatomic, assign) CGFloat currentVideoTime;

- (void)setupSound;
- (void)processAsset;

@end

@implementation GPUImageMovie

@synthesize url = _url;
@synthesize asset = _asset;
@synthesize runBenchmark = _runBenchmark;
@synthesize playAtActualSpeed = _playAtActualSpeed;
@synthesize delegate = _delegate;
@synthesize shouldRepeat = _shouldRepeat;

#pragma mark -
#pragma mark Initialization and teardown

- (id)initWithURL:(NSURL *)url;
{
    if (!(self = [super init]))
    {
        return nil;
    }
    
    [self yuvConversionSetup];
    
    self.url = url;
    self.asset = nil;
    
    return self;
}

- (id)initWithAsset:(AVAsset *)asset;
{
    if (!(self = [super init]))
    {
        return nil;
    }
    
    [self yuvConversionSetup];
    
    self.url = nil;
    self.asset = asset;
    
    return self;
}

- (id)initWithPlayerItem:(AVPlayerItem *)playerItem;
{
    if (!(self = [super init]))
    {
        return nil;
    }
    
    [self yuvConversionSetup];
    
    self.url = nil;
    self.asset = nil;
    self.playerItem = playerItem;
    
    return self;
}

- (void)yuvConversionSetup;
{
    if ([GPUImageContext supportsFastTextureUpload])
    {
        runSynchronouslyOnVideoProcessingQueue(^{
            [GPUImageContext useImageProcessingContext];
            
            _preferredConversion = kColorConversion709;
            self.isFullYUVRange       = YES;
            self.yuvConversionProgram = [[GPUImageContext sharedImageProcessingContext] programForVertexShaderString:kGPUImageVertexShaderString fragmentShaderString:kGPUImageYUVFullRangeConversionForLAFragmentShaderString];
            
            if (!self.yuvConversionProgram.initialized)
            {
                [self.yuvConversionProgram addAttribute:@"position"];
                [self.yuvConversionProgram addAttribute:@"inputTextureCoordinate"];
                
                if (![self.yuvConversionProgram link])
                {
                    NSString *progLog = [self.yuvConversionProgram programLog];
                    NSLog(@"Program link log: %@", progLog);
                    NSString *fragLog = [self.yuvConversionProgram fragmentShaderLog];
                    NSLog(@"Fragment shader compile log: %@", fragLog);
                    NSString *vertLog = [self.yuvConversionProgram vertexShaderLog];
                    NSLog(@"Vertex shader compile log: %@", vertLog);
                    self.yuvConversionProgram = nil;
                    NSAssert(NO, @"Filter shader link failed");
                }
            }
            
            self.yuvConversionPositionAttribute = [self.yuvConversionProgram attributeIndex:@"position"];
            self.yuvConversionTextureCoordinateAttribute = [self.yuvConversionProgram attributeIndex:@"inputTextureCoordinate"];
            self.yuvConversionLuminanceTextureUniform = [self.yuvConversionProgram uniformIndex:@"luminanceTexture"];
            self.yuvConversionChrominanceTextureUniform = [self.yuvConversionProgram uniformIndex:@"chrominanceTexture"];
            self.yuvConversionMatrixUniform = [self.yuvConversionProgram uniformIndex:@"colorConversionMatrix"];
            
            [GPUImageContext setActiveShaderProgram:self.yuvConversionProgram];
            
            glEnableVertexAttribArray(self.yuvConversionPositionAttribute);
            glEnableVertexAttribArray(self.yuvConversionTextureCoordinateAttribute);
        });
    }
}

#pragma mark -
#pragma mark Movie processing

- (void)enableSynchronizedEncodingUsingMovieWriter:(GPUImageMovieWriter *)movieWriter;
{
    self.synchronizedMovieWriter = movieWriter;
    movieWriter.encodingLiveVideo = NO;
}

- (void)startProcessing
{
    [self endProcessing];
    if( self.playerItem ) {
        [self processPlayerItem];
        return;
    }
    if(self.url == nil)
    {
        [self processAsset];
        return;
    }
    
    [self setupSound];
    
    if (_shouldRepeat) self.keepLooping = YES;
    
    self.previousFrameTime = kCMTimeZero;
    self.previousActualFrameTime = CFAbsoluteTimeGetCurrent();
    
    NSDictionary *inputOptions = [NSDictionary dictionaryWithObject:[NSNumber numberWithBool:YES] forKey:AVURLAssetPreferPreciseDurationAndTimingKey];
    AVURLAsset *inputAsset = [[AVURLAsset alloc] initWithURL:self.url options:inputOptions];
    
    GPUImageMovie __block *blockSelf = self;
    
    [inputAsset loadValuesAsynchronouslyForKeys:[NSArray arrayWithObject:@"tracks"] completionHandler: ^{
        NSError *error = nil;
        AVKeyValueStatus tracksStatus = [inputAsset statusOfValueForKey:@"tracks" error:&error];
        if (tracksStatus != AVKeyValueStatusLoaded)
        {
            return;
        }
        blockSelf.asset = inputAsset;
        [blockSelf processAsset];
        blockSelf = nil;
    }];
}

- (AVAssetReader*)createAssetReader
{
    NSError *error = nil;
    AVAssetReader *assetReader = [AVAssetReader assetReaderWithAsset:self.asset error:&error];
    
    NSMutableDictionary *outputSettings = [NSMutableDictionary dictionary];
    if ([GPUImageContext supportsFastTextureUpload]) {
        [outputSettings setObject:@(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) forKey:(id)kCVPixelBufferPixelFormatTypeKey];
        self.isFullYUVRange = YES;
    }
    else {
        [outputSettings setObject:@(kCVPixelFormatType_32BGRA) forKey:(id)kCVPixelBufferPixelFormatTypeKey];
        self.isFullYUVRange = NO;
    }
    
    // Maybe set alwaysCopiesSampleData to NO on iOS 5.0 for faster video decoding
    AVAssetReaderTrackOutput *readerVideoTrackOutput = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:[[self.asset tracksWithMediaType:AVMediaTypeVideo] objectAtIndex:0] outputSettings:outputSettings];
    readerVideoTrackOutput.alwaysCopiesSampleData = NO;
    [assetReader addOutput:readerVideoTrackOutput];
    
    NSArray *audioTracks = [self.asset tracksWithMediaType:AVMediaTypeAudio];
    BOOL shouldRecordAudioTrack = (([audioTracks count] > 0) && (self.audioEncodingTarget != nil) );
    AVAssetReaderTrackOutput *readerAudioTrackOutput = nil;
    
    if (shouldRecordAudioTrack)
    {
        [self.audioEncodingTarget setShouldInvalidateAudioSampleWhenDone:YES];
        
        // This might need to be extended to handle movies with more than one audio track
        AVAssetTrack* audioTrack = [audioTracks objectAtIndex:0];
        readerAudioTrackOutput = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:audioTrack outputSettings:nil];
        readerAudioTrackOutput.alwaysCopiesSampleData = NO;
        [assetReader addOutput:readerAudioTrackOutput];
    }
    
    return assetReader;
}

- (void)setupSound
{
    NSError *error;
    self.audioPlayer = [[AVAudioPlayer alloc] initWithContentsOfURL:self.url error:&error];
    self.audioPlayer.volume = self.volume;
    
    if (error) {
        NSLog(@"Failed to initialise sound with error:%@",error);
    }
    [self.audioPlayer prepareToPlay];
}

- (void)processAsset
{
    self.reader = [self createAssetReader];
    
    AVAssetReaderOutput *readerVideoTrackOutput = nil;
    AVAssetReaderOutput *readerAudioTrackOutput = nil;
    
    NSArray *audioTracks = [self.asset tracksWithMediaType:AVMediaTypeAudio];
    BOOL hasAudioTraks = [audioTracks count] > 0;
    BOOL shouldPlayAudio = hasAudioTraks && (self.volume > 0);
    
    if (shouldPlayAudio && self.reader.status != AVAssetReaderStatusReading){
        self.audioEncodingIsFinished = NO;
        
        // This might need to be extended to handle movies with more than one audio track
        AVAssetTrack* audioTrack = [audioTracks objectAtIndex:0];
        NSDictionary *audioReadSettings = [NSDictionary dictionaryWithObjectsAndKeys:
                                           [NSNumber numberWithInt:kAudioFormatLinearPCM], AVFormatIDKey,
                                           [NSNumber numberWithFloat:44100.0], AVSampleRateKey,
                                           [NSNumber numberWithInt:16], AVLinearPCMBitDepthKey,
                                           [NSNumber numberWithBool:NO], AVLinearPCMIsNonInterleaved,
                                           [NSNumber numberWithBool:NO], AVLinearPCMIsFloatKey,
                                           [NSNumber numberWithBool:NO], AVLinearPCMIsBigEndianKey,
                                           nil];
        
        readerAudioTrackOutput = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:audioTrack outputSettings:audioReadSettings];
        [self.reader addOutput:readerAudioTrackOutput];
        
        [self.audioPlayer setCurrentTime:self.currentVideoTime];
        [self.audioPlayer play];
    }
    
    self.audioEncodingIsFinished = YES;
    for( AVAssetReaderOutput *output in self.reader.outputs ) {
        if( [output.mediaType isEqualToString:AVMediaTypeAudio] ) {
            self.audioEncodingIsFinished = NO;
            readerAudioTrackOutput = output;
        }
        else if( [output.mediaType isEqualToString:AVMediaTypeVideo] ) {
            readerVideoTrackOutput = output;
        }
    }
    
    if (self.reader.status != AVAssetReaderStatusReading &&
        self.reader.status != AVAssetReaderStatusCancelled
        )
    {
        if([self.reader startReading] == NO)
        {
            NSLog(@"Error reading from file at URL: %@", self.url);
            return;
        }
    }
    
    __unsafe_unretained GPUImageMovie *weakSelf = self;
    
    if (self.synchronizedMovieWriter != nil)
    {
        [self.synchronizedMovieWriter setVideoInputReadyCallback:^{
            return [weakSelf readNextVideoFrameFromOutput:readerVideoTrackOutput];
        }];
        
        [self.synchronizedMovieWriter setAudioInputReadyCallback:^{
            return [weakSelf readNextAudioSampleFromOutput:readerAudioTrackOutput];
        }];
        
        [self.synchronizedMovieWriter setAudioInputReadyCallback:^{
            return [weakSelf readNextAudioSampleFromOutput:readerAudioTrackOutput];
        }];
        
        [self.synchronizedMovieWriter enableSynchronizationCallbacks];
    }
    else
    {
        while (self.reader.status == AVAssetReaderStatusReading && (!_shouldRepeat || self.keepLooping))
        {
            [weakSelf readNextVideoFrameFromOutput:readerVideoTrackOutput];
            
            if ( (readerAudioTrackOutput) && (!self.audioEncodingIsFinished) )
            {
                [weakSelf readNextAudioSampleFromOutput:readerAudioTrackOutput];
            }
            
        }
        
        if (self.reader.status == AVAssetReaderStatusCompleted) {
            
            [self.reader cancelReading];
            
            if (self.keepLooping) {
                self.reader = nil;
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self startProcessing];
                });
            } else {
                [weakSelf endProcessing];
            }
            
        }
    }
}

- (void)processPlayerItem
{
    runSynchronouslyOnVideoProcessingQueue(^{
        self.displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(displayLinkCallback:)];
        [self.displayLink addToRunLoop:[NSRunLoop currentRunLoop] forMode:NSRunLoopCommonModes];
        [self.displayLink setPaused:YES];
        
        dispatch_queue_t videoProcessingQueue = [GPUImageContext sharedContextQueue];
        NSMutableDictionary *pixBuffAttributes = [NSMutableDictionary dictionary];
        if ([GPUImageContext supportsFastTextureUpload]) {
            [pixBuffAttributes setObject:@(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) forKey:(id)kCVPixelBufferPixelFormatTypeKey];
        }
        else {
            [pixBuffAttributes setObject:@(kCVPixelFormatType_32BGRA) forKey:(id)kCVPixelBufferPixelFormatTypeKey];
        }
        self.playerItemOutput = [[AVPlayerItemVideoOutput alloc] initWithPixelBufferAttributes:pixBuffAttributes];
        [self.playerItemOutput setDelegate:self queue:videoProcessingQueue];
        
        [_playerItem addOutput:self.playerItemOutput];
        [self.playerItemOutput requestNotificationOfMediaDataChangeWithAdvanceInterval:0.1];
    });
}

- (void)outputMediaDataWillChange:(AVPlayerItemOutput *)sender
{
    // Restart display link.
    [self.displayLink setPaused:NO];
}

- (void)displayLinkCallback:(CADisplayLink *)sender
{
    /*
     The callback gets called once every Vsync.
     Using the display link's timestamp and duration we can compute the next time the screen will be refreshed, and copy the pixel buffer for that time
     This pixel buffer can then be processed and later rendered on screen.
     */
    // Calculate the nextVsync time which is when the screen will be refreshed next.
    CFTimeInterval nextVSync = ([sender timestamp] + [sender duration]);
    
    CMTime outputItemTime = [self.playerItemOutput itemTimeForHostTime:nextVSync];
    
    if ([self.playerItemOutput hasNewPixelBufferForItemTime:outputItemTime]) {
        __unsafe_unretained GPUImageMovie *weakSelf = self;
        CVPixelBufferRef pixelBuffer = [self.playerItemOutput copyPixelBufferForItemTime:outputItemTime itemTimeForDisplay:NULL];
        if( pixelBuffer )
            runSynchronouslyOnVideoProcessingQueue(^{
                [weakSelf processMovieFrame:pixelBuffer withSampleTime:outputItemTime];
                CFRelease(pixelBuffer);
            });
    }
}

- (BOOL)readNextVideoFrameFromOutput:(AVAssetReaderOutput *)readerVideoTrackOutput;
{
    if (self.reader.status == AVAssetReaderStatusReading && ! self.videoEncodingIsFinished && readerVideoTrackOutput)
    {
        CMSampleBufferRef sampleBufferRef = [readerVideoTrackOutput copyNextSampleBuffer];
        if (sampleBufferRef != NULL)
        {
            if (_playAtActualSpeed)
            {
                CMTime currentSampleTime = CMSampleBufferGetOutputPresentationTimeStamp(sampleBufferRef);
                //NSLog(@"read a video frame: %@", CFBridgingRelease(CMTimeCopyDescription(kCFAllocatorDefault, CMSampleBufferGetOutputPresentationTimeStamp(sampleBufferRef))));
                
                // Do this outside of the video processing queue to not slow that down while waiting
                CFAbsoluteTime currentActualTime = CFAbsoluteTimeGetCurrent();
                
                CGFloat frameTimeOffset= CMTimeGetSeconds(currentSampleTime);
                CGFloat actualTimeOffset = currentActualTime - self.startActualFrameTime;
                
                actualTimeOffset = [self.audioPlayer currentTime];
                
                if (frameTimeOffset - actualTimeOffset > 0.0f)
                {
                    usleep(1000000.0 * (frameTimeOffset - actualTimeOffset));
                }
                
                self.previousFrameTime = currentSampleTime;
                self.previousActualFrameTime = CFAbsoluteTimeGetCurrent();
            }
            
            __unsafe_unretained GPUImageMovie *weakSelf = self;
            runSynchronouslyOnVideoProcessingQueue(^{
                [weakSelf processMovieFrame:sampleBufferRef];
                CMSampleBufferInvalidate(sampleBufferRef);
                CFRelease(sampleBufferRef);
            });
            
            return YES;
        }
        else
        {
            if (!self.keepLooping) {
                self.videoEncodingIsFinished = YES;
                if( self.videoEncodingIsFinished && self.audioEncodingIsFinished )
                    [self endProcessing];
            }
        }
    }
    else if (self.synchronizedMovieWriter != nil)
    {
        if (self.reader.status == AVAssetReaderStatusCompleted)
        {
            [self endProcessing];
        }
    }
    return NO;
}

- (BOOL)readNextAudioSampleFromOutput:(AVAssetReaderOutput *)readerAudioTrackOutput;
{
    if (self.reader.status == AVAssetReaderStatusReading && ! self.audioEncodingIsFinished)
    {
        CMSampleBufferRef audioSampleBufferRef = [readerAudioTrackOutput copyNextSampleBuffer];
        
        if (audioSampleBufferRef)
        {
            //NSLog(@"read an audio frame: %@", CFBridgingRelease(CMTimeCopyDescription(kCFAllocatorDefault, CMSampleBufferGetOutputPresentationTimeStamp(audioSampleBufferRef))));
            [self.audioEncodingTarget processAudioBuffer:audioSampleBufferRef];
            CFRelease(audioSampleBufferRef);
            return YES;
        }
        else
        {
            if (!self.keepLooping) {
                self.audioEncodingIsFinished = YES;
                if( self.videoEncodingIsFinished && self.audioEncodingIsFinished )
                    [self endProcessing];
            }
        }
    }
    else if (self.synchronizedMovieWriter != nil)
    {
        if (self.reader.status == AVAssetReaderStatusCompleted || self.reader.status == AVAssetReaderStatusFailed ||
            self.reader.status == AVAssetReaderStatusCancelled)
        {
            [self endProcessing];
        }
    }
    return NO;
}

- (void)processMovieFrame:(CMSampleBufferRef)movieSampleBuffer;
{
    //    CMTimeGetSeconds
    //    CMTimeSubtract
    
    CMTime currentSampleTime = CMSampleBufferGetOutputPresentationTimeStamp(movieSampleBuffer);
    CVImageBufferRef movieFrame = CMSampleBufferGetImageBuffer(movieSampleBuffer);
    
    self.processingFrameTime = currentSampleTime;
    [self processMovieFrame:movieFrame withSampleTime:currentSampleTime];
}

- (float)progress
{
    if ( AVAssetReaderStatusReading == self.reader.status )
    {
        float current = self.processingFrameTime.value * 1.0f / self.processingFrameTime.timescale;
        float duration = self.asset.duration.value * 1.0f / self.asset.duration.timescale;
        return current / duration;
    }
    else if ( AVAssetReaderStatusCompleted == self.reader.status )
    {
        return 1.f;
    }
    else
    {
        return 0.f;
    }
}

- (void)processMovieFrame:(CVPixelBufferRef)movieFrame withSampleTime:(CMTime)currentSampleTime
{
    int bufferHeight = (int) CVPixelBufferGetHeight(movieFrame);
    int bufferWidth = (int) CVPixelBufferGetWidth(movieFrame);
    
    CFTypeRef colorAttachments = CVBufferGetAttachment(movieFrame, kCVImageBufferYCbCrMatrixKey, NULL);
    if (colorAttachments != NULL)
    {
        if(CFStringCompare(colorAttachments, kCVImageBufferYCbCrMatrix_ITU_R_601_4, 0) == kCFCompareEqualTo)
        {
            if (self.isFullYUVRange)
            {
                _preferredConversion = kColorConversion601FullRange;
            }
            else
            {
                _preferredConversion = kColorConversion601;
            }
        }
        else
        {
            _preferredConversion = kColorConversion709;
        }
    }
    else
    {
        if (self.isFullYUVRange)
        {
            _preferredConversion = kColorConversion601FullRange;
        }
        else
        {
            _preferredConversion = kColorConversion601;
        }
        
    }
    
    CFAbsoluteTime startTime = CFAbsoluteTimeGetCurrent();
    
    // Fix issue 1580
    [GPUImageContext useImageProcessingContext];
    
    if ([GPUImageContext supportsFastTextureUpload])
    {
        CVOpenGLESTextureRef luminanceTextureRef = NULL;
        CVOpenGLESTextureRef chrominanceTextureRef = NULL;
        
        //        if (captureAsYUV && [GPUImageContext deviceSupportsRedTextures])
        if (CVPixelBufferGetPlaneCount(movieFrame) > 0) // Check for YUV planar inputs to do RGB conversion
        {
            
            if ( (self.imageBufferWidth != bufferWidth) && (self.imageBufferHeight != bufferHeight) )
            {
                self.imageBufferWidth = bufferWidth;
                self.imageBufferHeight = bufferHeight;
            }
            
            CVReturn err;
            // Y-plane
            glActiveTexture(GL_TEXTURE4);
            if ([GPUImageContext deviceSupportsRedTextures])
            {
                err = CVOpenGLESTextureCacheCreateTextureFromImage(kCFAllocatorDefault, [[GPUImageContext sharedImageProcessingContext] coreVideoTextureCache], movieFrame, NULL, GL_TEXTURE_2D, GL_LUMINANCE, bufferWidth, bufferHeight, GL_LUMINANCE, GL_UNSIGNED_BYTE, 0, &luminanceTextureRef);
            }
            else
            {
                err = CVOpenGLESTextureCacheCreateTextureFromImage(kCFAllocatorDefault, [[GPUImageContext sharedImageProcessingContext] coreVideoTextureCache], movieFrame, NULL, GL_TEXTURE_2D, GL_LUMINANCE, bufferWidth, bufferHeight, GL_LUMINANCE, GL_UNSIGNED_BYTE, 0, &luminanceTextureRef);
            }
            if (err)
            {
                NSLog(@"Error at CVOpenGLESTextureCacheCreateTextureFromImage %d", err);
            }
            
            self.luminanceTexture = CVOpenGLESTextureGetName(luminanceTextureRef);
            glBindTexture(GL_TEXTURE_2D, self.luminanceTexture);
            glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
            glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
            
            // UV-plane
            glActiveTexture(GL_TEXTURE5);
            if ([GPUImageContext deviceSupportsRedTextures])
            {
                err = CVOpenGLESTextureCacheCreateTextureFromImage(kCFAllocatorDefault, [[GPUImageContext sharedImageProcessingContext] coreVideoTextureCache], movieFrame, NULL, GL_TEXTURE_2D, GL_LUMINANCE_ALPHA, bufferWidth/2, bufferHeight/2, GL_LUMINANCE_ALPHA, GL_UNSIGNED_BYTE, 1, &chrominanceTextureRef);
            }
            else
            {
                err = CVOpenGLESTextureCacheCreateTextureFromImage(kCFAllocatorDefault, [[GPUImageContext sharedImageProcessingContext] coreVideoTextureCache], movieFrame, NULL, GL_TEXTURE_2D, GL_LUMINANCE_ALPHA, bufferWidth/2, bufferHeight/2, GL_LUMINANCE_ALPHA, GL_UNSIGNED_BYTE, 1, &chrominanceTextureRef);
            }
            if (err)
            {
                NSLog(@"Error at CVOpenGLESTextureCacheCreateTextureFromImage %d", err);
            }
            
            self.chrominanceTexture = CVOpenGLESTextureGetName(chrominanceTextureRef);
            glBindTexture(GL_TEXTURE_2D, self.chrominanceTexture);
            glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
            glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
            
            //            if (!allTargetsWantMonochromeData)
            //            {
            [self convertYUVToRGBOutput];
            //            }
            
            for (id<GPUImageInput> currentTarget in targets)
            {
                NSInteger indexOfObject = [targets indexOfObject:currentTarget];
                NSInteger targetTextureIndex = [[targetTextureIndices objectAtIndex:indexOfObject] integerValue];
                [currentTarget setInputSize:CGSizeMake(bufferWidth, bufferHeight) atIndex:targetTextureIndex];
                [currentTarget setInputFramebuffer:outputFramebuffer atIndex:targetTextureIndex];
            }
            
            [outputFramebuffer unlock];
            
            for (id<GPUImageInput> currentTarget in targets)
            {
                NSInteger indexOfObject = [targets indexOfObject:currentTarget];
                NSInteger targetTextureIndex = [[targetTextureIndices objectAtIndex:indexOfObject] integerValue];
                [currentTarget newFrameReadyAtTime:currentSampleTime atIndex:targetTextureIndex];
            }
            
            CVPixelBufferUnlockBaseAddress(movieFrame, 0);
            CFRelease(luminanceTextureRef);
            CFRelease(chrominanceTextureRef);
        }
        else
        {
            // TODO: Mesh this with the new framebuffer cache
            //            CVPixelBufferLockBaseAddress(movieFrame, 0);
            //
            //            CVReturn err = CVOpenGLESTextureCacheCreateTextureFromImage(kCFAllocatorDefault, coreVideoTextureCache, movieFrame, NULL, GL_TEXTURE_2D, GL_RGBA, bufferWidth, bufferHeight, GL_BGRA, GL_UNSIGNED_BYTE, 0, &texture);
            //
            //            if (!texture || err) {
            //                NSLog(@"Movie CVOpenGLESTextureCacheCreateTextureFromImage failed (error: %d)", err);
            //                NSAssert(NO, @"Camera failure");
            //                return;
            //            }
            //
            //            outputTexture = CVOpenGLESTextureGetName(texture);
            //            //        glBindTexture(CVOpenGLESTextureGetTarget(texture), outputTexture);
            //            glBindTexture(GL_TEXTURE_2D, outputTexture);
            //            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
            //            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
            //            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
            //            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
            //
            //            for (id<GPUImageInput> currentTarget in targets)
            //            {
            //                NSInteger indexOfObject = [targets indexOfObject:currentTarget];
            //                NSInteger targetTextureIndex = [[targetTextureIndices objectAtIndex:indexOfObject] integerValue];
            //
            //                [currentTarget setInputSize:CGSizeMake(bufferWidth, bufferHeight) atIndex:targetTextureIndex];
            //                [currentTarget setInputTexture:outputTexture atIndex:targetTextureIndex];
            //
            //                [currentTarget newFrameReadyAtTime:currentSampleTime atIndex:targetTextureIndex];
            //            }
            //
            //            CVPixelBufferUnlockBaseAddress(movieFrame, 0);
            //            CVOpenGLESTextureCacheFlush(coreVideoTextureCache, 0);
            //            CFRelease(texture);
            //
            //            outputTexture = 0;
        }
    }
    else
    {
        // Upload to texture
        CVPixelBufferLockBaseAddress(movieFrame, 0);
        
        outputFramebuffer = [[GPUImageContext sharedFramebufferCache] fetchFramebufferForSize:CGSizeMake(bufferWidth, bufferHeight) textureOptions:self.outputTextureOptions onlyTexture:YES];
        
        glBindTexture(GL_TEXTURE_2D, [outputFramebuffer texture]);
        // Using BGRA extension to pull in video frame data directly
        glTexImage2D(GL_TEXTURE_2D,
                     0,
                     self.outputTextureOptions.internalFormat,
                     bufferWidth,
                     bufferHeight,
                     0,
                     self.outputTextureOptions.format,
                     self.outputTextureOptions.type,
                     CVPixelBufferGetBaseAddress(movieFrame));
        
        for (id<GPUImageInput> currentTarget in targets)
        {
            NSInteger indexOfObject = [targets indexOfObject:currentTarget];
            NSInteger targetTextureIndex = [[targetTextureIndices objectAtIndex:indexOfObject] integerValue];
            [currentTarget setInputSize:CGSizeMake(bufferWidth, bufferHeight) atIndex:targetTextureIndex];
            [currentTarget setInputFramebuffer:outputFramebuffer atIndex:targetTextureIndex];
        }
        
        [outputFramebuffer unlock];
        
        for (id<GPUImageInput> currentTarget in targets)
        {
            NSInteger indexOfObject = [targets indexOfObject:currentTarget];
            NSInteger targetTextureIndex = [[targetTextureIndices objectAtIndex:indexOfObject] integerValue];
            [currentTarget newFrameReadyAtTime:currentSampleTime atIndex:targetTextureIndex];
        }
        CVPixelBufferUnlockBaseAddress(movieFrame, 0);
    }
    
    if (_runBenchmark)
    {
        CFAbsoluteTime currentFrameTime = (CFAbsoluteTimeGetCurrent() - startTime);
        NSLog(@"Current frame time : %f ms", 1000.0 * currentFrameTime);
    }
}

- (void)endProcessing;
{
    self.keepLooping = NO;
    [self.displayLink setPaused:YES];
    [self.audioPlayer stop];
    
    for (id<GPUImageInput> currentTarget in targets)
    {
        [currentTarget endProcessing];
    }
    
    if (self.synchronizedMovieWriter != nil)
    {
        [self.synchronizedMovieWriter setVideoInputReadyCallback:^{return NO;}];
        [self.synchronizedMovieWriter setAudioInputReadyCallback:^{return NO;}];
    }
    
    if (self.playerItem && (self.displayLink != nil))
    {
        [self.displayLink invalidate]; // remove from all run loops
        self.displayLink = nil;
    }
    
    if ([self.delegate respondsToSelector:@selector(didCompletePlayingMovie)]) {
        [self.delegate didCompletePlayingMovie];
    }
    self.delegate = nil;
}

- (void)cancelProcessing
{
    if (self.reader) {
        [self.reader cancelReading];
    }
    [self endProcessing];
}

- (void)convertYUVToRGBOutput;
{
    [GPUImageContext setActiveShaderProgram:self.yuvConversionProgram];
    outputFramebuffer = [[GPUImageContext sharedFramebufferCache] fetchFramebufferForSize:CGSizeMake(self.imageBufferWidth, self.imageBufferHeight) onlyTexture:NO];
    [outputFramebuffer activateFramebuffer];
    
    glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
    glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
    
    static const GLfloat squareVertices[] = {
        -1.0f, -1.0f,
        1.0f, -1.0f,
        -1.0f,  1.0f,
        1.0f,  1.0f,
    };
    
    static const GLfloat textureCoordinates[] = {
        0.0f, 0.0f,
        1.0f, 0.0f,
        0.0f, 1.0f,
        1.0f, 1.0f,
    };
    
    glActiveTexture(GL_TEXTURE4);
    glBindTexture(GL_TEXTURE_2D, self.luminanceTexture);
    glUniform1i(self.yuvConversionLuminanceTextureUniform, 4);
    
    glActiveTexture(GL_TEXTURE5);
    glBindTexture(GL_TEXTURE_2D, self.chrominanceTexture);
    glUniform1i(self.yuvConversionChrominanceTextureUniform, 5);
    
    glUniformMatrix3fv(self.yuvConversionMatrixUniform, 1, GL_FALSE, _preferredConversion);
    
    glVertexAttribPointer(self.yuvConversionPositionAttribute, 2, GL_FLOAT, 0, 0, squareVertices);
    glVertexAttribPointer(self.yuvConversionTextureCoordinateAttribute, 2, GL_FLOAT, 0, 0, textureCoordinates);
    
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
}

- (AVAssetReader*)assetReader {
    return self.reader;
}

- (void)setVolume:(NSUInteger)volume
{
    _volume = volume;
    if (self.audioPlayer)
    {
        self.audioPlayer.volume = volume;
    }
}

@end
