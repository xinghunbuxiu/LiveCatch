#import "LixhPlayerEngine.h"
#import "LixhAudioOutput.h"
#import "LixhPixelTexture.h"
#import <AVFoundation/AVFoundation.h>

#include "lixh_player.h"
#include <libavutil/frame.h>
#include <libavutil/pixfmt.h>

#include <stdatomic.h>
#include <string.h>

static CVPixelBufferRef LixhUploadSoftwareFrame(const AVFrame *f) {
  if (!f || f->width <= 0 || f->height <= 0 || !f->data[0]) return NULL;
  OSType cvfmt = 0;
  if (f->format == AV_PIX_FMT_YUV420P || f->format == AV_PIX_FMT_YUVJ420P)
    cvfmt = kCVPixelFormatType_420YpCbCr8Planar;
  else if (f->format == AV_PIX_FMT_NV12)
    cvfmt = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
  else
    return NULL;
  CVPixelBufferRef pix = NULL;
  NSDictionary *attrs = @{(id)kCVPixelBufferIOSurfacePropertiesKey : @{}};
  if (CVPixelBufferCreate(kCFAllocatorDefault, f->width, f->height, cvfmt,
                          (__bridge CFDictionaryRef)attrs, &pix) != kCVReturnSuccess)
    return NULL;
  CVPixelBufferLockBaseAddress(pix, 0);
  int ok = 0;
  do {
    int cw = (f->width + 1) / 2, ch = (f->height + 1) / 2;
    uint8_t *d0 = CVPixelBufferGetBaseAddressOfPlane(pix, 0);
    size_t rb0 = CVPixelBufferGetBytesPerRowOfPlane(pix, 0);
    if (!d0) break;
    for (int y = 0; y < f->height; y++)
      memcpy(d0 + (size_t)y * rb0, f->data[0] + (size_t)y * f->linesize[0],
             (size_t)f->width);
    uint8_t *d1 = CVPixelBufferGetBaseAddressOfPlane(pix, 1);
    size_t rb1 = CVPixelBufferGetBytesPerRowOfPlane(pix, 1);
    if (!d1) break;
    if (f->format == AV_PIX_FMT_YUV420P || f->format == AV_PIX_FMT_YUVJ420P) {
      uint8_t *d2 = CVPixelBufferGetBaseAddressOfPlane(pix, 2);
      size_t rb2 = CVPixelBufferGetBytesPerRowOfPlane(pix, 2);
      if (!d2) break;
      for (int y = 0; y < ch; y++) {
        memcpy(d1 + (size_t)y * rb1, f->data[1] + (size_t)y * f->linesize[1],
               (size_t)cw);
        memcpy(d2 + (size_t)y * rb2, f->data[2] + (size_t)y * f->linesize[2],
               (size_t)cw);
      }
    } else {
      for (int y = 0; y < ch; y++)
        memcpy(d1 + (size_t)y * rb1, f->data[1] + (size_t)y * f->linesize[1],
               (size_t)cw * 2);
    }
    ok = 1;
  } while (0);
  CVPixelBufferUnlockBaseAddress(pix, 0);
  if (!ok) {
    CFRelease(pix);
    return NULL;
  }
  return pix;
}

@interface LixhPlayerEngine ()
@property(nonatomic, weak) NSObject<FlutterTextureRegistry> *textures;
@property(nonatomic, strong) LixhPixelTexture *texture;
@property(nonatomic, strong) LixhAudioOutput *audio;
@property(nonatomic, strong) NSThread *playThread;
@property(nonatomic, copy) NSString *lastError;
@property(nonatomic, assign) int64_t textureId;
@property(nonatomic, assign) int texWidth;
@property(nonatomic, assign) int texHeight;
@end

@implementation LixhPlayerEngine {
  void *_player;
  atomic_bool _videoEnabled;
  atomic_ullong _videoFrames;
  atomic_ullong _presentOk;
  atomic_ullong _audioFrames;
  atomic_int _decodeHw;
  int _latencyTargetMs;
  int _latencyMaxMs;
  NSTimeInterval _lastPresent;
  NSTimeInterval _lastNotify;
}

- (instancetype)initWithTextures:(NSObject<FlutterTextureRegistry> *)textures {
  self = [super init];
  if (self) {
    _textures = textures;
    _audio = [[LixhAudioOutput alloc] init];
    _textureId = -1;
    _texWidth = 1280;
    _texHeight = 720;
    atomic_init(&_videoEnabled, false);
    atomic_init(&_videoFrames, 0);
    atomic_init(&_presentOk, 0);
    atomic_init(&_audioFrames, 0);
    atomic_init(&_decodeHw, -1);
    _latencyTargetMs = 200;
    _latencyMaxMs = 700;
  }
  return self;
}

- (void)dealloc {
  [self disposeVideoTexture];
  [self stop];
}

- (void)setErr:(NSString *)msg {
  @synchronized(self) {
    self.lastError = msg ?: @"";
  }
}

static int OnVideo(void *opaque, int kind, int width, int height, int64_t pts_ms,
                   int64_t duration_ms, const LixhNativeFrame *frame) {
  (void)pts_ms;
  (void)duration_ms;
  return [(__bridge LixhPlayerEngine *)opaque handleVideoKind:kind
                                                        width:width
                                                       height:height
                                                        frame:frame];
}

static void OnAudio(void *opaque, int sample_rate, int channels, int format,
                    int64_t pts_ms, const float *samples, int sample_count) {
  (void)format;
  (void)pts_ms;
  LixhPlayerEngine *self = (__bridge LixhPlayerEngine *)opaque;
  if (!samples || sample_count <= 0) return;
  @synchronized(self) {
    if (!self->_player) return;
  }
  atomic_fetch_add(&self->_audioFrames, 1);
  [self.audio pushSamples:samples frames:sample_count channels:channels sampleRate:sample_rate];
}

static void OnEvent(void *opaque, int type, int code, const char *message) {
  (void)code;
  if (type != LIXH_EVT_ERROR || !message) return;
  [(__bridge LixhPlayerEngine *)opaque setErr:[NSString stringWithUTF8String:message]];
}

- (int)handleVideoKind:(int)kind
                 width:(int)width
                height:(int)height
                 frame:(const LixhNativeFrame *)frame {
  if (!frame || !frame->handle0 || width <= 0 || height <= 0) return -1;
  atomic_fetch_add(&_videoFrames, 1);
  if (!atomic_load(&_videoEnabled)) return 1;

  NSTimeInterval now = CFAbsoluteTimeGetCurrent();
  if (_lastPresent != 0 && (now - _lastPresent) * 1000.0 < 15.0) return 1;

  CVPixelBufferRef pix = NULL;
  if (kind == LIXH_VIDEO_VIDEOTOOLBOX) {
    atomic_store(&_decodeHw, 1);
    pix = (CVPixelBufferRef)frame->handle0;
    CFRetain(pix);
  } else if (kind == LIXH_VIDEO_SOFTWARE) {
    atomic_store(&_decodeHw, 0);
    pix = LixhUploadSoftwareFrame((const AVFrame *)frame->handle0);
  } else {
    return -1;
  }
  if (!pix) return -1;

  LixhPixelTexture *tex = nil;
  @synchronized(self) { tex = self.texture; }
  if (!tex) {
    CFRelease(pix);
    return 1;
  }
  [tex setPixelBuffer:pix];
  CFRelease(pix);
  _lastPresent = now;
  atomic_fetch_add(&_presentOk, 1);
  [self notifyFrame];
  return 0;
}

- (void)notifyFrame {
  if (self.textureId < 0 || !self.textures) return;
  NSTimeInterval now = CFAbsoluteTimeGetCurrent();
  if (_lastNotify != 0 && (now - _lastNotify) * 1000.0 < 12.0) return;
  _lastNotify = now;
  [self.textures textureFrameAvailable:self.textureId];
}

- (NSDictionary *)createVideoTextureWidth:(int)width
                                   height:(int)height
                                  error:(NSError **)error {
  (void)error;
  [self disposeVideoTexture];
  if (width < 2) width = 1280;
  if (height < 2) height = 720;
  self.texWidth = width;
  self.texHeight = height;
  LixhPixelTexture *tex = [[LixhPixelTexture alloc] init];
  [tex presentColorR:0.02f g:0.02f b:0.02f width:width height:height];
  int64_t tid = [self.textures registerTexture:tex];
  self.texture = tex;
  self.textureId = tid;
  [self.textures textureFrameAvailable:tid];
  return @{
    @"textureId" : @(tid),
    @"width" : @(width),
    @"height" : @(height),
    @"path" : @"flutter_texture",
  };
}

- (BOOL)presentTestFrameR:(float)r g:(float)g b:(float)b error:(NSError **)error {
  if (!self.texture || self.textureId < 0) {
    if (error)
      *error = [NSError errorWithDomain:@"lixh_player"
                                     code:1
                                 userInfo:@{NSLocalizedDescriptionKey : @"No texture"}];
    return NO;
  }
  [self.texture presentColorR:r g:g b:b width:self.texWidth height:self.texHeight];
  [self.textures textureFrameAvailable:self.textureId];
  return YES;
}

- (BOOL)openUrl:(NSString *)url headers:(NSString *)headers error:(NSError **)error {
  [self stop];
  LixhCallbacks cb = {0};
  cb.opaque = (__bridge void *)self;
  cb.on_video = OnVideo;
  cb.on_audio = OnAudio;
  cb.on_event = OnEvent;
  void *player = lixh_player_create(&cb);
  if (!player) {
    [self setErr:@"lixh_player_create failed"];
    if (error)
      *error = [NSError errorWithDomain:@"lixh_player"
                                     code:2
                                 userInfo:@{NSLocalizedDescriptionKey : (self.lastError ?: @"")}];
    return NO;
  }
  if (headers.length > 0) {
    lixh_player_set_headers(player, headers.UTF8String);
  }
  if (lixh_player_open(player, url.UTF8String) < 0) {
    [self setErr:@"lixh_player_open failed"];
    lixh_player_destroy(player);
    if (error)
      *error = [NSError errorWithDomain:@"lixh_player"
                                     code:3
                                 userInfo:@{NSLocalizedDescriptionKey : (self.lastError ?: @"")}];
    return NO;
  }
  lixh_player_set_latency(player, _latencyTargetMs, _latencyMaxMs);
  lixh_player_set_video_sink(player, atomic_load(&_videoEnabled) ? 1 : 0);
  @synchronized(self) { _player = player; }
  NSLog(@"[lixh] open url=%lu chars", (unsigned long)url.length);
  return YES;
}

- (BOOL)startPlayback:(NSError **)error {
  void *player = NULL;
  @synchronized(self) { player = _player; }
  if (!player) {
    [self setErr:@"player not open"];
    if (error)
      *error = [NSError errorWithDomain:@"lixh_player"
                                     code:4
                                 userInfo:@{NSLocalizedDescriptionKey : (self.lastError ?: @"")}];
    return NO;
  }
  if (self.playThread) {
    [self setErr:@"already playing"];
    if (error)
      *error = [NSError errorWithDomain:@"lixh_player"
                                     code:5
                                 userInfo:@{NSLocalizedDescriptionKey : (self.lastError ?: @"")}];
    return NO;
  }
  [self.audio start];
  AVAudioSession *session = [AVAudioSession sharedInstance];
  NSError *sessErr = nil;
  [session setCategory:AVAudioSessionCategoryPlayback error:&sessErr];
  [session setActive:YES error:&sessErr];
  NSThread *th = [[NSThread alloc] initWithBlock:^{
    const int rc = lixh_player_play(player);
    if (rc < 0) {
      [self setErr:@"lixh_player_play failed"];
    }
  }];
  th.name = @"lixh-play";
  self.playThread = th;
  [th start];
  NSLog(@"[lixh] play");
  return YES;
}

- (void)stop {
  void *player = NULL;
  NSThread *th = nil;
  @synchronized(self) {
    player = _player;
    _player = NULL;
    th = self.playThread;
    self.playThread = nil;
  }
  if (player) lixh_player_stop(player);
  if (th) {
    while (!th.isFinished) {
      [NSThread sleepForTimeInterval:0.01];
    }
  }
  if (player) lixh_player_destroy(player);
  [self.audio stop];
}

- (void)setVideoEnabled:(BOOL)enabled {
  atomic_store(&_videoEnabled, enabled);
  void *player = NULL;
  @synchronized(self) { player = _player; }
  NSLog(@"[lixh] setVideoEnabled %s", enabled ? "true" : "false");
  if (player) lixh_player_set_video_sink(player, enabled ? 1 : 0);
}

- (void)setLatencyTargetMs:(int)targetMs maxMs:(int)maxMs {
  if (targetMs < 40) targetMs = 40;
  if (maxMs < targetMs) maxMs = targetMs;
  _latencyTargetMs = targetMs;
  _latencyMaxMs = maxMs;
  void *player = NULL;
  @synchronized(self) { player = _player; }
  NSLog(@"[lixh] setLatency target=%d max=%d", targetMs, maxMs);
  if (player) lixh_player_set_latency(player, targetMs, maxMs);
}

- (void)disposeVideoTexture {
  if (self.textureId >= 0 && self.textures) {
    [self.textures unregisterTexture:self.textureId];
  }
  self.textureId = -1;
  self.texture = nil;
}

- (NSDictionary *)stats {
  uint64_t vf = atomic_load(&_videoFrames);
  uint64_t po = atomic_load(&_presentOk);
  uint64_t af = atomic_load(&_audioFrames);
  int dhw = atomic_load(&_decodeHw);
  int qms = [self.audio queuedMs];
  NSString *err = @"";
  uint64_t dropped = 0, bread = 0;
  int64_t lag = 0;
  int vw = 0, vh = 0;
  @synchronized(self) {
    err = self.lastError ?: @"";
    if (_player) {
      LixhStats core = {0};
      if (lixh_player_get_stats(_player, &core) == 0) {
        dropped = core.dropped_frames;
        bread = core.bytes_read;
        lag = core.input_buffer_ms;
        vw = core.video_width;
        vh = core.video_height;
        if (dhw < 0 && core.decode_hw >= 0) dhw = core.decode_hw;
      }
    }
  }
  return @{
    @"textureId" : @(self.textureId),
    @"videoFrames" : @(vf),
    @"presentOk" : @(po),
    @"audioFrames" : @(af),
    @"decodeHw" : @(dhw),
    @"lastError" : err,
    @"droppedFrames" : @(dropped),
    @"bytesRead" : @(bread),
    @"lagMs" : @(lag),
    @"audioQueueMs" : @(qms),
    @"videoWidth" : @(vw),
    @"videoHeight" : @(vh),
  };
}

@end
