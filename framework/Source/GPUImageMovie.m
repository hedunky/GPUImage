#import "GPUImageMovie.h"
#import "GPUImageMovieWriter.h"
#import "GPUImageFilter.h"
#import "GPUImageVideoCamera.h"

# define ONE_FRAME_DURATION 0.03

static void *AVPlayerItemStatusContext = &AVPlayerItemStatusContext;

@interface GPUImageMovie () <AVPlayerItemOutputPullDelegate>
{
    const GLfloat *preferredConversion;
}

@property (nonatomic, assign) BOOL videoEncodingIsFinished;

@property (nonatomic, strong) AVPlayerItem *playerItem;
@property (nonatomic, strong) AVAssetReader *assetReader;
@property (nonatomic, strong) AVAssetReaderTrackOutput *ouputTrack;

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
- (void)createAssetReader;

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
    }
    
    return self;
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
        runAsynchronouslyOnVideoProcessingQueue(^{
            [self prepareForPlayback];
            
            if (self.shouldRepeat) self.keepLooping = YES;
            
            self.previousFrameTime = kCMTimeZero;
            self.previousActualFrameTime = CFAbsoluteTimeGetCurrent();
            
            NSDictionary *inputOptions = [NSDictionary dictionaryWithObject:[NSNumber numberWithBool:YES] forKey:AVURLAssetPreferPreciseDurationAndTimingKey];
            AVAsset *inputAsset = self.playerItem.asset;
            
            GPUImageMovie __block *blockSelf = self;
            
            [inputAsset loadValuesAsynchronouslyForKeys:[NSArray arrayWithObject:@"tracks"] completionHandler: ^{
                NSError *error = nil;
                AVKeyValueStatus tracksStatus = [inputAsset statusOfValueForKey:@"tracks" error:&error];
                if (tracksStatus != AVKeyValueStatusLoaded)
                {
                    return;
                }
                [blockSelf prepareForPlayback];
                blockSelf = nil;
            }];
        });
    }
}


- (void)prepareForPlayback
{
    [self createAssetReader];
    
    AVAssetReaderOutput *readerVideoTrackOutput = nil;
    
    for( AVAssetReaderOutput *output in self.assetReader.outputs )
    {
        if( [output.mediaType isEqualToString:AVMediaTypeVideo] )
        {
            readerVideoTrackOutput = output;
        }
    }
    
    if ([self.assetReader startReading] == NO)
    {
        NSLog(@"Error reading from file at URL: %@", @":(");
        return;
    }
    
    __unsafe_unretained GPUImageMovie *weakSelf = self;
    
    while (self.assetReader.status == AVAssetReaderStatusReading && (!self.shouldRepeat || self.keepLooping))
    {
        [weakSelf readNextVideoFrameFromOutput:self.ouputTrack];
    }
    
    if (self.assetReader.status == AVAssetReaderStatusCompleted) {
        
        [self.assetReader cancelReading];
        
        if (self.keepLooping) {
            self.assetReader = nil;
            dispatch_async(dispatch_get_main_queue(), ^{
                [self startProcessing];
            });
        } else {
            [weakSelf endProcessing];
        }
        
    }
}

- (void)createAssetReader
{
    AVAsset *asset = self.playerItem.asset;
    NSError *error = nil;
    self.assetReader = [AVAssetReader assetReaderWithAsset:asset
                                                     error:&error];
    
    NSMutableDictionary *outputSettings = [NSMutableDictionary dictionary];
    [outputSettings setObject:@(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) forKey:(id)kCVPixelBufferPixelFormatTypeKey];
    
    self.isFullYUVRange = YES;
    
    // Maybe set alwaysCopiesSampleData to NO on iOS 5.0 for faster video decoding
    self.ouputTrack = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:[asset tracksWithMediaType:AVMediaTypeVideo][0]
                                                                 outputSettings:outputSettings];
    self.ouputTrack.alwaysCopiesSampleData = NO;
    [self.assetReader addOutput:self.ouputTrack];
}

- (BOOL)readNextVideoFrameFromOutput:(AVAssetReaderOutput *)readerVideoTrackOutput;
{
    if (self.assetReader.status == AVAssetReaderStatusReading &&
        !self.videoEncodingIsFinished)
    {
        CMSampleBufferRef sampleBufferRef = [readerVideoTrackOutput copyNextSampleBuffer];
        if (sampleBufferRef)
        {
            //NSLog(@"read a video frame: %@", CFBridgingRelease(CMTimeCopyDescription(kCFAllocatorDefault, CMSampleBufferGetOutputPresentationTimeStamp(sampleBufferRef))));
            if (_playAtActualSpeed)
            {
                // Do this outside of the video processing queue to not slow that down while waiting
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
    
    return NO;
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
        }
        
        CVPixelBufferUnlockBaseAddress(movieFrame, 0);
        CFRelease(luminanceTextureRef);
        CFRelease(chrominanceTextureRef);
    }
    
}

- (void)endProcessing;
{
    self.keepLooping = NO;
    
    for (id<GPUImageInput> currentTarget in targets)
    {
        [currentTarget endProcessing];
    }
    
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
}

@end
