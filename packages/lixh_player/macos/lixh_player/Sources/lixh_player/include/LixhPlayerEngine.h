#import <FlutterMacOS/FlutterMacOS.h>

@interface LixhPlayerEngine : NSObject
- (instancetype)initWithTextures:(NSObject<FlutterTextureRegistry> *)textures;
- (NSDictionary *)createVideoTextureWidth:(int)width height:(int)height failure:(NSError **)failure;
- (BOOL)presentTestFrameR:(float)r g:(float)g b:(float)b failure:(NSError **)failure;
- (BOOL)openUrl:(NSString *)url headers:(NSString *)headers failure:(NSError **)failure;
- (BOOL)startPlayback:(NSError **)failure;
- (void)stop;
- (void)setVideoEnabled:(BOOL)enabled;
- (void)disposeVideoTexture;
- (NSDictionary *)stats;
@end
