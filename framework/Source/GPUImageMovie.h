#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import "GPUImageContext.h"
#import "GPUImageOutput.h"

/** Protocol for getting Movie played callback.
 */
@protocol GPUImageMovieDelegate <NSObject>

- (void)didCompletePlayingMovie;
@end

/** Source object for filtering movies
 */
@interface GPUImageMovie : GPUImageOutput

/** This enables the benchmarking mode, which logs out instantaneous and average frame times to the console
 */
@property(readwrite, nonatomic, nonatomic) BOOL runBenchmark;

/** This determines whether the video should repeat (loop) at the end and restart from the beginning. Defaults to NO.
 */
@property(readwrite, nonatomic, nonatomic) BOOL shouldRepeat;

/** Volume for audio track.
 */
@property(nonatomic, assign) NSUInteger volume;

/** This is used to send the delete Movie did complete playing alert
 */
@property (readwrite, nonatomic, assign) id <GPUImageMovieDelegate>delegate;

/// @name Initialization and teardown
- (id)initWithURL:(NSURL *)url;

- (void)yuvConversionSetup;

- (void)setURL:(NSURL *)url;

/// @name Movie processing
- (void)startProcessing;
- (void)endProcessing;
- (void)cancelProcessing;

@end
