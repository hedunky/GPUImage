#import "GPUImageMovie.h"
#import "GPUImageMovieWriter.h"
#import "GPUImageFilter.h"
#import "GPUImageVideoCamera.h"

# define ONE_FRAME_DURATION 0.03

static void *AVPlayerItemStatusContext = &AVPlayerItemStatusContext;

@interface GPUImageMovie () <AVPlayerItemOutputPullDelegate>
{
    const GLfloat *preferredConversion;
    AVPlayer *_player;
}

@property (nonatomic, strong) AVPlayerItem *playerItem;
@property (nonatomic, strong) AVPlayer *player;
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

@property (nonatomic, assign) CFAbsoluteTime startActualFrameTime;
@property (nonatomic, assign) CGFloat currentVideoTime;

- (void)prepareForPlayback;

@end

@implementation GPUImageMovie

#pragma mark -
#pragma mark Initialization and teardown

- (instancetype)init
{
    self = [super init];
    if (self)
    {
        
    }
    
    return self;
}

- (id)initWithURL:(NSURL *)url;
{
    self = [self init];
    
    if (self)
    {
        [self yuvConversionSetup];
        [self setURL: url];
    }
    
    return self;
}

- (AVPlayer *)player
{
    if (!_player)
    {
        _player = [[AVPlayer alloc] init];
        [_player addObserver:self
                  forKeyPath:@"currentItem.status"
                     options:NSKeyValueObservingOptionNew
                     context:AVPlayerItemStatusContext];
        
    }
    
    return _player;
}

- (AVPlayerItemOutput *)playerItemOutput
{
    if (!_playerItemOutput)
    {
        // Setup AVPlayerItemVideoOutput with the required pixelbuffer attributes.
        NSDictionary *pixBuffAttributes = @{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)};
        _playerItemOutput = [[AVPlayerItemVideoOutput alloc] initWithPixelBufferAttributes:pixBuffAttributes];
        
        dispatch_queue_t videoProcessingQueue = [GPUImageContext sharedContextQueue];
        [_playerItemOutput setDelegate:self queue:videoProcessingQueue];
    }
    
    return _playerItemOutput;
}

- (CADisplayLink *)displayLink
{
    if (!_displayLink)
    {
        // Setup CADisplayLink which will callback displayPixelBuffer: at every vsync.
        _displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(displayLinkCallback:)];
        [_displayLink addToRunLoop:[NSRunLoop currentRunLoop] forMode:NSRunLoopCommonModes];
        // [_displayLink setPaused:YES];
    }
    
    return _displayLink;
}

- (void)setURL:(NSURL *)url
{
    AVPlayerItem *item = [AVPlayerItem playerItemWithURL:url];
    self.playerItem = item;
}

- (void)setPlayerItem:(AVPlayerItem *)playerItem
{
    [self willChangeValueForKey:@"playerItem"];
    
    _playerItem = playerItem;
    
    [self didChangeValueForKey:@"playerItem"];
    
    if (playerItem)
    {
        [self prepareForPlayback];
    }
}



- (void)prepareForPlayback
{
    [self.player pause];
    [self.displayLink setPaused:YES];
    
    // Remove video output from old item, if any.
    [self.playerItem removeOutput:self.playerItemOutput];
    AVAsset *asset = self.playerItem.asset;
    
    [asset loadValuesAsynchronouslyForKeys:@[@"tracks"] completionHandler:^
     {
         
         if ([asset statusOfValueForKey:@"tracks" error:nil] == AVKeyValueStatusLoaded) {
             NSArray *tracks = [asset tracksWithMediaType:AVMediaTypeVideo];
             if ([tracks count] > 0) {
                 // Choose the first video track.
                 AVAssetTrack *videoTrack = [tracks objectAtIndex:0];
                 [videoTrack loadValuesAsynchronouslyForKeys:@[@"preferredTransform"] completionHandler:^{
                     
                     if ([videoTrack statusOfValueForKey:@"preferredTransform" error:nil] == AVKeyValueStatusLoaded) {
                         
                         
                         dispatch_async(dispatch_get_main_queue(), ^{
                             [self.playerItem addOutput:self.playerItemOutput];
                             [self.player replaceCurrentItemWithPlayerItem:self.playerItem];
                             [self.playerItemOutput requestNotificationOfMediaDataChangeWithAdvanceInterval:ONE_FRAME_DURATION];
                             [self.player play];
                         });
                         
                     }
                     
                 }];
             }
         }
         
     }];
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
    //    if (context == AVPlayerItemStatusContext) {
    //        AVPlayerStatus status = [change[NSKeyValueChangeNewKey] integerValue];
    //        switch (status) {
    //            case AVPlayerItemStatusUnknown:
    //                break;
    //            case AVPlayerItemStatusReadyToPlay:
    //                self.playerView.presentationRect = [[_player currentItem] presentationSize];
    //                break;
    //            case AVPlayerItemStatusFailed:
    //                [self stopLoadingAnimationAndHandleError:[[_player currentItem] error]];
    //                break;
    //        }
    //    }
    //    else {
    //        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
    //    }
}

- (void)yuvConversionSetup;
{
    if ([GPUImageContext supportsFastTextureUpload])
    {
        runSynchronouslyOnVideoProcessingQueue(^
                                               {
                                                   [GPUImageContext useImageProcessingContext];
                                                   
                                                   preferredConversion = kColorConversion709;
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

- (void)startProcessing
{
    [self endProcessing];
    
    if (self.shouldRepeat) self.keepLooping = YES;
    
    self.previousFrameTime = kCMTimeZero;
    self.previousActualFrameTime = CFAbsoluteTimeGetCurrent();
    
    
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
    
    if ([self.playerItemOutput hasNewPixelBufferForItemTime:outputItemTime])
    {
        __unsafe_unretained GPUImageMovie *weakSelf = self;
        CVPixelBufferRef pixelBuffer = [self.playerItemOutput copyPixelBufferForItemTime:outputItemTime itemTimeForDisplay:NULL];
        if( pixelBuffer )
            runSynchronouslyOnVideoProcessingQueue(^{
                [weakSelf processMovieFrame:pixelBuffer withSampleTime:outputItemTime];
                CFRelease(pixelBuffer);
            });
    }
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
    //    if ( AVAssetReaderStatusReading == self.reader.status )
    //    {
    //        float current = self.processingFrameTime.value * 1.0f / self.processingFrameTime.timescale;
    //        float duration = self.playerItem.asset.duration.value * 1.0f / self.playerItem.asset.duration.timescale;
    //        return current / duration;
    //    }
    //    else if ( AVAssetReaderStatusCompleted == self.reader.status )
    //    {
    //        return 1.f;
    //    }
    //    else
    //    {
    //        return 0.f;
    //    }
    
    return 0.0f;
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
                preferredConversion = kColorConversion601FullRange;
            }
            else
            {
                preferredConversion = kColorConversion601;
            }
        }
        else
        {
            preferredConversion = kColorConversion709;
        }
    }
    else
    {
        if (self.isFullYUVRange)
        {
            preferredConversion = kColorConversion601FullRange;
        }
        else
        {
            preferredConversion = kColorConversion601;
        }
        
    }
    
    // Fix issue 1580
    [GPUImageContext useImageProcessingContext];
    
    CVOpenGLESTextureRef luminanceTextureRef = NULL;
    CVOpenGLESTextureRef chrominanceTextureRef = NULL;
    
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
        
        err = CVOpenGLESTextureCacheCreateTextureFromImage(kCFAllocatorDefault, [[GPUImageContext sharedImageProcessingContext] coreVideoTextureCache], movieFrame, NULL, GL_TEXTURE_2D, GL_LUMINANCE, bufferWidth, bufferHeight, GL_LUMINANCE, GL_UNSIGNED_BYTE, 0, &luminanceTextureRef);
        
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
        
        err = CVOpenGLESTextureCacheCreateTextureFromImage(kCFAllocatorDefault, [[GPUImageContext sharedImageProcessingContext] coreVideoTextureCache], movieFrame, NULL, GL_TEXTURE_2D, GL_LUMINANCE_ALPHA, bufferWidth/2, bufferHeight/2, GL_LUMINANCE_ALPHA, GL_UNSIGNED_BYTE, 1, &chrominanceTextureRef);
        
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
    
}

- (void)endProcessing;
{
    self.keepLooping = NO;
    //  [self.displayLink setPaused:YES];
    
    for (id<GPUImageInput> currentTarget in targets)
    {
        [currentTarget endProcessing];
    }
    
    //    if (self.playerItem && (self.displayLink != nil))
    //    {
    //        [self.displayLink invalidate]; // remove from all run loops
    //        self.displayLink = nil;
    //    }
    
    if ([self.delegate respondsToSelector:@selector(didCompletePlayingMovie)]) {
        [self.delegate didCompletePlayingMovie];
    }
    self.delegate = nil;
}

- (void)cancelProcessing
{
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
    
    glUniformMatrix3fv(self.yuvConversionMatrixUniform, 1, GL_FALSE, preferredConversion);
    
    glVertexAttribPointer(self.yuvConversionPositionAttribute, 2, GL_FLOAT, 0, 0, squareVertices);
    glVertexAttribPointer(self.yuvConversionTextureCoordinateAttribute, 2, GL_FLOAT, 0, 0, textureCoordinates);
    
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
}

- (void)setVolume:(NSUInteger)volume
{
    _volume = volume;
    if (self.player)
    {
        self.player.volume = volume;
    }
}

- (void)dealloc
{
    [self.player removeObserver:self
                     forKeyPath:@"currentItem.status"
                        context:AVPlayerItemStatusContext];
    
}

@end
