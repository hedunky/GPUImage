#import "GPUImageMovie.h"
#import "GPUImageMovieWriter.h"
#import "GPUImageFilter.h"
#import "GPUImageVideoCamera.h"
#import "GPUImageAudioPlayer.h"

static void *AVPlayerItemStatusContext = &AVPlayerItemStatusContext;

GPUImageRotationMode RotationModeFromOrientation(UIImageOrientation orientation)
{
    GPUImageRotationMode mode = kGPUImageNoRotation;
    switch (orientation)
    {
        case UIImageOrientationDown:
            mode = kGPUImageFlipVertical | kGPUImageFlipHorizonal;
            break;
        case UIImageOrientationLeft:
            mode = kGPUImageRotateLeft;
            break;
        case UIImageOrientationRight:
            mode = kGPUImageRotateRight;
            break;
            
        default:
            break;
    }
    
    return mode;
}

@interface GPUImageMovie () <AVPlayerItemOutputPullDelegate>
{
    const GLfloat *preferredConversion;
    
    dispatch_semaphore_t frameRenderingSemaphore;
}

@property (nonatomic, assign) GPUImageRotationMode preferredOrientation;

@property (nonatomic, assign) dispatch_queue_t audio_queue;
@property (nonatomic, strong) GPUImageAudioPlayer *audioPlayer;


@property (nonatomic, strong) AVPlayerItem *playerItem;
@property (nonatomic, strong) AVAssetReader *assetReader;
@property (nonatomic, strong) CADisplayLink *displayLink;
//TODO: Move to NSTimer

@property (nonatomic, strong) AVAssetReaderTrackOutput *videoOutputTrack;
@property (nonatomic, strong) AVAssetReaderTrackOutput *audioOutputTrack;

@property (nonatomic, assign) CMTime previousFrameTime;
@property (nonatomic, assign) CMTime processingFrameTime;
@property (nonatomic, assign) CFAbsoluteTime previousActualFrameTime;

@property (nonatomic, assign) GLuint luminanceTexture;
@property (nonatomic, assign) GLuint chrominanceTexture;
@property (nonatomic, strong) GLProgram *yuvConversionProgram;

@property (nonatomic, assign) GLint yuvConversionPositionAttribute;
@property (nonatomic, assign) GLint yuvConversionTextureCoordinateAttribute;
@property (nonatomic, assign) GLint yuvConversionLuminanceTextureUniform;
@property (nonatomic, assign) GLint yuvConversionChrominanceTextureUniform;
@property (nonatomic, assign) GLint yuvConversionMatrixUniform;

@property (nonatomic, assign) int imageBufferWidth;
@property (nonatomic, assign) int imageBufferHeight;

- (void)createDisplayLink;
- (void)prepareForPlayback;
- (void)createAssetReader;
- (void)loadAsset;
- (void)processAsset;

- (void)play;
- (void)stop;

- (void)displayLinkCallback:(CADisplayLink *)sender;

- (void)readNextVideoFrameFromOutput:(AVAssetReaderOutput *)readerVideoTrackOutput;
- (void)readNextAudioSampleFromOutput:(AVAssetReaderTrackOutput *)readerAudioTrackOutput;

@end

@implementation GPUImageMovie

#pragma mark -
#pragma mark Initialization and teardown

- (id)initWithURL:(NSURL *)url;
{
    self = [super init];
    
    if (self)
    {
        [self yuvConversionSetup];
        [self setURL: url];
        
        frameRenderingSemaphore = dispatch_semaphore_create(1);
    }
    
    return self;
}

- (dispatch_queue_t)audio_queue
{
    if (!_audio_queue)
    {
        _audio_queue = dispatch_queue_create("GPUAudioQueue", nil);
    }
    
    return _audio_queue;
}

- (GPUImageAudioPlayer *)audioPlayer
{
    if (!_audioPlayer)
    {
        _audioPlayer = [[GPUImageAudioPlayer alloc] init];
    }
    
    return _audioPlayer;
}

- (void)setURL:(NSURL *)url
{
    NSLog(@"Loading %@", url);
    AVPlayerItem *item = [AVPlayerItem playerItemWithURL:url];
    self.playerItem = item;
}

- (void)setPlayerItem:(AVPlayerItem *)playerItem
{
    [self willChangeValueForKey:@"playerItem"];
    
    _playerItem = playerItem;
    
    [self didChangeValueForKey:@"playerItem"];
}

- (void)setVolume:(NSUInteger)volume
{
    self.audioPlayer.volume = volume;
}

- (NSUInteger)volume
{
    return self.audioPlayer.volume;
}

- (void)createDisplayLink
{
    self.displayLink = [CADisplayLink displayLinkWithTarget:self
                                                   selector:@selector(displayLinkCallback:)];
    //self.displayLink.paused = YES;
    self.displayLink.frameInterval = 1;
    [self.displayLink addToRunLoop:[NSRunLoop currentRunLoop] forMode:NSRunLoopCommonModes];
}

- (void)prepareForPlayback
{
    [self createAssetReader];
    [self loadAsset];
}

- (void)createAssetReader
{
    AVAsset *asset = self.playerItem.asset;
    NSError *error = nil;
    self.assetReader = [AVAssetReader assetReaderWithAsset:asset
                                                     error:&error];
    
    NSMutableDictionary *videoOutputSettings = [NSMutableDictionary dictionary];
    [videoOutputSettings setObject:@(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) forKey:(id)kCVPixelBufferPixelFormatTypeKey];
    
    NSArray *videoTracks = [asset tracksWithMediaType:AVMediaTypeVideo];
    if (videoTracks.count > 0)
    {
        self.videoOutputTrack = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:videoTracks[0]
                                                                           outputSettings:videoOutputSettings];
        self.videoOutputTrack.alwaysCopiesSampleData = NO; //Set to NO for faster video decoding.
        [self.assetReader addOutput:self.videoOutputTrack];
    }
    
    NSDictionary *audioOutputSettings = [NSDictionary dictionaryWithObjectsAndKeys:
                                         [NSNumber numberWithInt:kAudioFormatLinearPCM], AVFormatIDKey,
                                         [NSNumber numberWithFloat:44100.0], AVSampleRateKey,
                                         [NSNumber numberWithInt:16], AVLinearPCMBitDepthKey,
                                         [NSNumber numberWithBool:NO], AVLinearPCMIsNonInterleaved,
                                         [NSNumber numberWithBool:NO], AVLinearPCMIsFloatKey,
                                         [NSNumber numberWithBool:NO], AVLinearPCMIsBigEndianKey,
                                         nil];
    
    
    NSArray *audioTracks = [asset tracksWithMediaType:AVMediaTypeAudio];
    if (audioTracks.count > 0)
    {
        self.audioOutputTrack = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:audioTracks[0]
                                                                           outputSettings:audioOutputSettings];
        
        [self.assetReader addOutput:self.audioOutputTrack];
    }
}

- (void)loadAsset
{
    self.previousFrameTime = kCMTimeZero;
    self.previousActualFrameTime = CFAbsoluteTimeGetCurrent();
    
    AVAsset *inputAsset = self.playerItem.asset;
    GPUImageMovie __block * blockSelf = self;
    
    [inputAsset loadValuesAsynchronouslyForKeys:@[@"tracks"] completionHandler: ^
     {
         NSError *error = nil;
         AVKeyValueStatus tracksStatus = [inputAsset statusOfValueForKey:@"tracks" error:&error];
         
         if (tracksStatus != AVKeyValueStatusLoaded)
         {
             return;
         }
         
         /*
          The orientation of the camera while recording affects the orientation of the images received from an AVPlayerItemVideoOutput. Here we compute a rotation that is used to correctly orientate the video.
          */
         
         AVAssetTrack* videoTrack = [[inputAsset tracksWithMediaType:AVMediaTypeVideo] objectAtIndex:0];
         CGAffineTransform preferredTransform = [videoTrack preferredTransform];
         
         //TODO: Figure out how this works.
         if (preferredTransform.a == 0 && preferredTransform.b == 1.0 && preferredTransform.c == -1.0 && preferredTransform.d == 0) {
             self.preferredOrientation = RotationModeFromOrientation(UIImageOrientationRight);
         }
         if (preferredTransform.a == 0 && preferredTransform.b == -1.0 && preferredTransform.c == 1.0 && preferredTransform.d == 0) {
             self.preferredOrientation = RotationModeFromOrientation(UIImageOrientationLeft);
         }
         if (preferredTransform.a == 1.0 && preferredTransform.b == 0 && preferredTransform.c == 0 && preferredTransform.d == 1.0) {
             self.preferredOrientation =  RotationModeFromOrientation(UIImageOrientationUp);
         }
         if (preferredTransform.a == -1.0 && preferredTransform.b == 0 && preferredTransform.c == 0 && preferredTransform.d == -1.0) {
             self.preferredOrientation =  RotationModeFromOrientation(UIImageOrientationDown);
         }
         
         dispatch_async(dispatch_get_main_queue(),
                        ^{
                            [blockSelf processAsset];
                        });
     }];
}

- (void)processAsset
{
    if (self.assetReader.status == AVAssetReaderStatusReading ||
        self.assetReader.outputs.count == 0)
    {
        return;
    }
    
    if ([self.assetReader startReading] == NO)
    {
        return;
    }
    
    [self createDisplayLink];
    [self.audioPlayer startPlaying];
}

- (void)play
{
    if (self.assetReader.status == AVAssetReaderStatusReading)
    {
        return;
    }
    
    [self stop];
    [self prepareForPlayback];
}

- (void)stop
{
    if (self.assetReader.status != AVAssetReaderStatusReading)
    {
        return;
    }
    
    [self.displayLink invalidate];
    [self.audioPlayer stopPlaying];
    
    [self.assetReader cancelReading];
    self.assetReader = nil;
}

//Come up with way to sync Video to Audio.
- (void)readNextVideoFrameFromOutput:(AVAssetReaderOutput *)readerVideoTrackOutput
{
    CMSampleBufferRef sampleBufferRef = [readerVideoTrackOutput copyNextSampleBuffer];
    if (sampleBufferRef)
    {
        // Do this outside of the video processing queue to not slow that down while waiting
        // TODO: Update code to rely on more performant model.
        CMTime currentSampleTime = CMSampleBufferGetOutputPresentationTimeStamp(sampleBufferRef);
        CMTime differenceFromLastFrame = CMTimeSubtract(currentSampleTime, self.previousFrameTime);
        CFAbsoluteTime currentActualTime = CFAbsoluteTimeGetCurrent();
        
        CGFloat frameTimeDifference = CMTimeGetSeconds(differenceFromLastFrame);
        CGFloat actualTimeDifference = currentActualTime - self.previousActualFrameTime;
        
        if (frameTimeDifference > actualTimeDifference)
        {
            usleep(1000000.0 * (frameTimeDifference - actualTimeDifference));
        }
        
        self.previousFrameTime = currentSampleTime;
        self.previousActualFrameTime = CFAbsoluteTimeGetCurrent();
        
        __unsafe_unretained GPUImageMovie *weakSelf = self;
        runAsynchronouslyOnVideoProcessingQueue(^{
            [weakSelf processMovieFrame:sampleBufferRef];
            CMSampleBufferInvalidate(sampleBufferRef);
            CFRelease(sampleBufferRef);
        });
    }
}

- (void)readNextAudioSampleFromOutput:(AVAssetReaderTrackOutput *)readerAudioTrackOutput
{
    if (!self.audioPlayer.readyForMoreBytes)
    {
        return;
    }
    
    CMSampleBufferRef sampleBufferRef = [readerAudioTrackOutput copyNextSampleBuffer];
    if (sampleBufferRef)
    {
        CFRetain(sampleBufferRef);
        dispatch_async(self.audio_queue, ^
                       {
                           [self.audioPlayer copyBuffer:sampleBufferRef];
                           
                           CMSampleBufferInvalidate(sampleBufferRef);
                           CFRelease(sampleBufferRef);
                       });
        CFRelease(sampleBufferRef);
    }
}

- (void)yuvConversionSetup;
{
    runSynchronouslyOnVideoProcessingQueue(^
                                           {
                                               [GPUImageContext useImageProcessingContext];
                                               
                                               preferredConversion = kColorConversion709;
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

#pragma mark - CADisplayLink Callback

- (void)displayLinkCallback:(CADisplayLink *)sender
{
    if (dispatch_semaphore_wait(frameRenderingSemaphore, DISPATCH_TIME_NOW) != 0)
    {
        return;
    }
    
    __weak GPUImageMovie *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        
        switch (weakSelf.assetReader.status)
        {
            case AVAssetReaderStatusReading:
                [weakSelf readNextVideoFrameFromOutput:weakSelf.videoOutputTrack];
                [weakSelf readNextAudioSampleFromOutput:weakSelf.audioOutputTrack];
                break;
                
            case AVAssetReaderStatusCompleted:
                
                [weakSelf.assetReader cancelReading];
                
                if (weakSelf.shouldRepeat)
                {
                    weakSelf.assetReader = nil;
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [weakSelf startProcessing];
                    });
                }
                else
                {
                    [weakSelf endProcessing];
                }
                break;
                
            default:
                break;
        }
        
        dispatch_semaphore_signal(frameRenderingSemaphore);
    });
}

#pragma mark -
#pragma mark Movie processing

- (void)startProcessing
{
    [self play];
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

- (void)processMovieFrame:(CVPixelBufferRef)movieFrame withSampleTime:(CMTime)currentSampleTime
{
    int bufferHeight = (int) CVPixelBufferGetHeight(movieFrame);
    int bufferWidth = (int) CVPixelBufferGetWidth(movieFrame);
    
    CFTypeRef colorAttachments = CVBufferGetAttachment(movieFrame, kCVImageBufferYCbCrMatrixKey, NULL);
    if (colorAttachments != NULL)
    {
        if(CFStringCompare(colorAttachments, kCVImageBufferYCbCrMatrix_ITU_R_601_4, 0) == kCFCompareEqualTo)
        {
            preferredConversion = kColorConversion601FullRange;
        }
        else
        {
            preferredConversion = kColorConversion709;
        }
    }
    else
    {
        preferredConversion = kColorConversion601FullRange;
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
        
        [self convertYUVToRGBOutput];
        
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
            [currentTarget setInputRotation:self.preferredOrientation  atIndex:targetTextureIndex];
        }
        
        CVPixelBufferUnlockBaseAddress(movieFrame, 0);
        CFRelease(luminanceTextureRef);
        CFRelease(chrominanceTextureRef);
    }
    
}

- (void)endProcessing;
{
    [self stop];
    
    for (id<GPUImageInput> currentTarget in targets)
    {
        [currentTarget endProcessing];
    }
    
    if ([self.delegate respondsToSelector:@selector(didCompletePlayingMovie)])
    {
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

- (void)dealloc
{
    [self endProcessing];
}

@end
