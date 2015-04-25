#import "GPUImageFilter.h"

extern NSString *const kGPUImageColorAveragingVertexShaderString;

@interface GPUImageAverageColor : GPUImageFilter
{
    GLint texelWidthUniform, texelHeightUniform;
    
    NSUInteger numberOfStages;
    
    GLubyte *rawImagePixels;
    CGSize finalStageSize;
}

// This block is called on the completion of color averaging for a frame
@property(nonatomic, copy) void(^colorAverageProcessingFinishedBlock)(GLubyte *rawImagePixels, NSUInteger totalPixels, CGSize size);

- (void)extractAverageColorAtFrameTime:(CMTime)frameTime;

@end
