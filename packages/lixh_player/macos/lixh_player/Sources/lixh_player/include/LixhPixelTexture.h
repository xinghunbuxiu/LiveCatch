#import <FlutterMacOS/FlutterMacOS.h>
#import <CoreVideo/CoreVideo.h>

@interface LixhPixelTexture : NSObject <FlutterTexture>
- (void)setPixelBuffer:(CVPixelBufferRef)buffer;
- (void)presentColorR:(float)r g:(float)g b:(float)b width:(int)width height:(int)height;
@end
