#import <Foundation/Foundation.h>

@interface LixhAudioOutput : NSObject
- (BOOL)start;
- (void)stop;
- (void)flush;
- (void)setMaxQueueMs:(int)ms;
- (void)pushSamples:(const float *)samples
             frames:(int)frames
           channels:(int)channels
         sampleRate:(int)sampleRate;
- (int)queuedMs;
@end
