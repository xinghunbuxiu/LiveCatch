#import <Flutter/Flutter.h>

@interface LixhPlayerEngine : NSObject
- (instancetype)initWithTextures:(NSObject<FlutterTextureRegistry> *)textures;
- (NSDictionary *)createVideoTextureWidth:(int)width
                                  height:(int)height
                                   error:(NSError **)error;
- (BOOL)presentTestFrameR:(float)r g:(float)g b:(float)b error:(NSError **)error;
- (BOOL)openUrl:(NSString *)url headers:(NSString *)headers error:(NSError **)error;
- (BOOL)startPlayback:(NSError **)error;
- (void)stop;
- (void)setVideoEnabled:(BOOL)enabled;
- (void)disposeVideoTexture;
- (NSDictionary *)stats;
@end
