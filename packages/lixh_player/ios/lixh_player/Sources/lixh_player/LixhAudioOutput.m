#import "LixhAudioOutput.h"
#import <AudioToolbox/AudioToolbox.h>

enum { kLixhRingCap = 48000 * 2 * 2 };

@interface LixhAudioOutput () {
  AudioQueueRef _queue;
  AudioQueueBufferRef _bufs[3];
  float _ring[kLixhRingCap];
  int _r;
  int _w;
  int _count;
  int _rate;
  int _ch;
  int _maxQueueMs;
  BOOL _primed;
  BOOL _started;
}
- (void)fillBuffer:(AudioQueueBufferRef)buf queue:(AudioQueueRef)q;
- (void)stopUnlocked;
- (BOOL)ensureQueueRate:(int)rate channels:(int)ch;
@end

@implementation LixhAudioOutput

- (instancetype)init {
  self = [super init];
  if (self) {
    _maxQueueMs = 120;
    _primed = NO;
  }
  return self;
}

- (void)setMaxQueueMs:(int)ms {
  @synchronized(self) {
    // Snap/listen may request ~60ms; grows toward 280ms on underrun.
    if (ms < 60) ms = 60;
    if (ms > 2000) ms = 2000;
    _maxQueueMs = ms;
  }
}

- (int)primeNeedMsLocked {
  if (_maxQueueMs <= 100) {
    int p = _maxQueueMs;
    if (p < 40) p = 40;
    return p;
  }
  int p = _maxQueueMs;
  if (p < 180) p = 180;
  if (p > 240) p = 240;
  return p;
}

static void LixhAqCallback(void *user, AudioQueueRef q, AudioQueueBufferRef buf) {
  LixhAudioOutput *self = (__bridge LixhAudioOutput *)user;
  [self fillBuffer:buf queue:q];
}

- (void)fillBuffer:(AudioQueueBufferRef)buf queue:(AudioQueueRef)q {
  @synchronized(self) {
    int frames = (int)(buf->mAudioDataBytesCapacity / (sizeof(float) * (unsigned)_ch));
    if (frames < 1 || _ch < 1) {
      memset(buf->mAudioData, 0, buf->mAudioDataBytesCapacity);
      buf->mAudioDataByteSize = buf->mAudioDataBytesCapacity;
      AudioQueueEnqueueBuffer(q, buf, 0, NULL);
      return;
    }
    float *dst = (float *)buf->mAudioData;
    int need = frames * _ch;
    if (!_primed) {
      int qms = (_rate > 0 && _ch > 0) ? (int)((_count / _ch) * 1000L / _rate) : 0;
      if (qms >= [self primeNeedMsLocked]) {
        _primed = YES;
      } else {
        memset(dst, 0, (size_t)need * sizeof(float));
        buf->mAudioDataByteSize = (UInt32)(need * (int)sizeof(float));
        AudioQueueEnqueueBuffer(q, buf, 0, NULL);
        return;
      }
    }
    int got = 0;
    while (got < need && _count > 0) {
      int n = need - got;
      if (n > _count) n = _count;
      int to_end = kLixhRingCap - _r;
      if (n > to_end) n = to_end;
      memcpy(dst + got, _ring + _r, (size_t)n * sizeof(float));
      _r = (_r + n) % kLixhRingCap;
      _count -= n;
      got += n;
    }
    if (got < need) {
      memset(dst + got, 0, (size_t)(need - got) * sizeof(float));
      if (_maxQueueMs < 280) {
        int next = _maxQueueMs + 40;
        if (next > 280) next = 280;
        _maxQueueMs = next;
      }
    }
    buf->mAudioDataByteSize = (UInt32)(frames * _ch * (int)sizeof(float));
  }
  AudioQueueEnqueueBuffer(q, buf, 0, NULL);
}

- (BOOL)start {
  @synchronized(self) {
    return YES;
  }
}

- (BOOL)ensureQueueRate:(int)rate channels:(int)ch {
  if (_started && _queue && _rate == rate && _ch == ch) return YES;
  [self stopUnlocked];
  _rate = rate > 0 ? rate : 48000;
  _ch = ch > 0 ? ch : 2;
  AudioStreamBasicDescription asbd = {0};
  asbd.mSampleRate = _rate;
  asbd.mFormatID = kAudioFormatLinearPCM;
  asbd.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
  asbd.mChannelsPerFrame = (UInt32)_ch;
  asbd.mBitsPerChannel = 32;
  asbd.mBytesPerFrame = 4 * (UInt32)_ch;
  asbd.mFramesPerPacket = 1;
  asbd.mBytesPerPacket = asbd.mBytesPerFrame;
  OSStatus st = AudioQueueNewOutput(&asbd, LixhAqCallback, (__bridge void *)self,
                                    NULL, kCFRunLoopCommonModes, 0, &_queue);
  if (st != noErr || !_queue) return NO;
  UInt32 bytes = (UInt32)(_rate / 50) * asbd.mBytesPerFrame;  // ~20ms
  if (bytes < 256) bytes = 256;
  for (int i = 0; i < 3; i++) {
    AudioQueueAllocateBuffer(_queue, bytes, &_bufs[i]);
    memset(_bufs[i]->mAudioData, 0, bytes);
    _bufs[i]->mAudioDataByteSize = bytes;
    AudioQueueEnqueueBuffer(_queue, _bufs[i], 0, NULL);
  }
  st = AudioQueueStart(_queue, NULL);
  if (st != noErr) return NO;
  _started = YES;
  return YES;
}

- (void)stopUnlocked {
  if (_queue) {
    AudioQueueStop(_queue, true);
    AudioQueueDispose(_queue, true);
    _queue = NULL;
  }
  memset(_bufs, 0, sizeof(_bufs));
  _started = NO;
  _primed = NO;
  _r = _w = _count = 0;
}

- (void)stop {
  @synchronized(self) { [self stopUnlocked]; }
}

- (void)flush {
  @synchronized(self) {
    _r = _w = _count = 0;
    _primed = NO;
  }
}

- (void)pushSamples:(const float *)samples
             frames:(int)frames
           channels:(int)channels
         sampleRate:(int)sampleRate {
  if (!samples || frames <= 0 || channels <= 0) return;
  @synchronized(self) {
    if (![self ensureQueueRate:sampleRate channels:channels]) return;
    int n = frames * channels;
    if (n > kLixhRingCap / 2) n = kLixhRingCap / 2;
    /* Cap app-side PCM to latency target (same semantics as Android).
       Ring capacity (~2s) is only a hard ceiling, not the live target. */
    int max_samples = kLixhRingCap;
    int cap_ms = _maxQueueMs;
    if (!_primed) {
      int p = [self primeNeedMsLocked];
      if (cap_ms < p) cap_ms = p;
    }
    if (cap_ms > 0 && _rate > 0 && _ch > 0) {
      max_samples = _ch * _rate * cap_ms / 1000;
      int floor_ms = _maxQueueMs < 100 ? 60 : (_maxQueueMs < 140 ? 80 : 100);
      if (max_samples < _ch * _rate * floor_ms / 1000) {
        max_samples = _ch * _rate * floor_ms / 1000;
      }
      if (max_samples > kLixhRingCap) max_samples = kLixhRingCap;
    }
    int trim_at = max_samples + max_samples / 4;
    int keep_ms = _maxQueueMs >= 160 ? 80 : (_maxQueueMs >= 100 ? 50 : 35);
    int min_keep = _primed ? (_ch * _rate * keep_ms / 1000) : 0;
    while (_count + n > trim_at && _count > min_keep) {
      int drop = _ch > 0 ? _ch * (_rate / 50) : n;
      if (drop < 1) drop = n;
      if (drop > _count - min_keep) drop = _count - min_keep;
      if (drop < 1) break;
      _r = (_r + drop) % kLixhRingCap;
      _count -= drop;
    }
    int off = 0;
    while (off < n) {
      int chunk = n - off;
      int to_end = kLixhRingCap - _w;
      if (chunk > to_end) chunk = to_end;
      memcpy(_ring + _w, samples + off, (size_t)chunk * sizeof(float));
      _w = (_w + chunk) % kLixhRingCap;
      _count += chunk;
      off += chunk;
    }
  }
}

- (int)queuedMs {
  @synchronized(self) {
    if (_rate <= 0 || _ch <= 0) return 0;
    return (int)((_count / _ch) * 1000L / _rate);
  }
}

- (void)dealloc {
  [self stop];
}

@end
