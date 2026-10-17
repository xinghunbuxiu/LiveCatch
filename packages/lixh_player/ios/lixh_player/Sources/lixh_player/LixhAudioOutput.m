#import "LixhAudioOutput.h"
#import <AudioToolbox/AudioToolbox.h>
#import <CoreFoundation/CoreFoundation.h>
#import <dispatch/dispatch.h>

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
  int _baseQueueMs;
  int _maxQueueMs;
  CFAbsoluteTime _lastUnderrun;
  CFAbsoluteTime _lastShrink;
  BOOL _primed;
  BOOL _started;
}
- (void)fillBuffer:(AudioQueueBufferRef)buf queue:(AudioQueueRef)q;
- (void)disposeQueue:(AudioQueueRef)q;
- (BOOL)ensureQueueRate:(int)rate channels:(int)ch;
- (void)maybeShrinkLocked;
@end

@implementation LixhAudioOutput

- (instancetype)init {
  self = [super init];
  if (self) {
    _baseQueueMs = 120;
    _maxQueueMs = 120;
    _primed = NO;
  }
  return self;
}

- (void)setMaxQueueMs:(int)ms {
  @synchronized(self) {
    // Snap/listen may request ~60ms; grows on underrun, shrinks when healthy.
    if (ms < 60) ms = 60;
    if (ms > 2000) ms = 2000;
    _baseQueueMs = ms;
    _maxQueueMs = ms;
    _lastUnderrun = 0;
    _lastShrink = 0;
  }
}

- (void)maybeShrinkLocked {
  if (_maxQueueMs <= _baseQueueMs || !_primed) return;
  CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
  if (_lastUnderrun > 0 && (now - _lastUnderrun) < 3.0) return;
  if (_lastShrink > 0 && (now - _lastShrink) < 1.0) return;
  int qms = (_rate > 0 && _ch > 0) ? (int)((_count / _ch) * 1000L / _rate) : 0;
  if (qms < 25) return;
  _lastShrink = now;
  int next = _maxQueueMs - 20;
  if (next < _baseQueueMs) next = _baseQueueMs;
  _maxQueueMs = next;
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
  BOOL shouldEnqueue = NO;
  @synchronized(self) {
    // Queue already swapped/disposed — never Enqueue under the lock or after stop.
    if (!_queue || q != _queue) {
      return;
    }
    int frames = (int)(buf->mAudioDataBytesCapacity / (sizeof(float) * (unsigned)_ch));
    if (frames < 1 || _ch < 1) {
      memset(buf->mAudioData, 0, buf->mAudioDataBytesCapacity);
      buf->mAudioDataByteSize = buf->mAudioDataBytesCapacity;
      shouldEnqueue = YES;
    } else {
      float *dst = (float *)buf->mAudioData;
      int need = frames * _ch;
      if (!_primed) {
        int qms = (_rate > 0 && _ch > 0) ? (int)((_count / _ch) * 1000L / _rate) : 0;
        if (qms >= [self primeNeedMsLocked]) {
          _primed = YES;
        } else {
          memset(dst, 0, (size_t)need * sizeof(float));
          buf->mAudioDataByteSize = (UInt32)(need * (int)sizeof(float));
          shouldEnqueue = YES;
        }
      }
      if (_primed) {
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
          _lastUnderrun = CFAbsoluteTimeGetCurrent();
          if (_maxQueueMs < 280) {
            int next = _maxQueueMs + 40;
            if (next > 280) next = 280;
            if (next < _baseQueueMs) next = _baseQueueMs;
            _maxQueueMs = next;
          }
        } else {
          [self maybeShrinkLocked];
        }
        buf->mAudioDataByteSize = (UInt32)(need * (int)sizeof(float));
        shouldEnqueue = YES;
      }
    }
  }
  // Enqueue outside the lock so Stop/Dispose cannot deadlock with the callback.
  if (shouldEnqueue) {
    AudioQueueEnqueueBuffer(q, buf, 0, NULL);
  }
}

- (BOOL)start {
  @synchronized(self) {
    return YES;
  }
}

- (void)disposeQueue:(AudioQueueRef)q {
  if (!q) return;
  // immediate=true waits for the callback and deadlocks if that callback
  // still needs this object. Stop returns immediately; dispose on a side queue.
  AudioQueueStop(q, false);
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
    AudioQueueDispose(q, true);
  });
}

- (BOOL)ensureQueueRate:(int)rate channels:(int)ch {
  // Must not be called while holding @synchronized(self): Stop/Dispose can
  // wait on the AQ callback, which also needs that lock.
  AudioQueueRef old = NULL;
  @synchronized(self) {
    if (_started && _queue && _rate == rate && _ch == ch) return YES;
    old = _queue;
    _queue = NULL;
    memset(_bufs, 0, sizeof(_bufs));
    _started = NO;
    _primed = NO;
    _r = _w = _count = 0;
  }
  [self disposeQueue:old];

  int useRate = rate > 0 ? rate : 48000;
  int useCh = ch > 0 ? ch : 2;
  AudioStreamBasicDescription asbd = {0};
  asbd.mSampleRate = useRate;
  asbd.mFormatID = kAudioFormatLinearPCM;
  asbd.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
  asbd.mChannelsPerFrame = (UInt32)useCh;
  asbd.mBitsPerChannel = 32;
  asbd.mBytesPerFrame = 4 * (UInt32)useCh;
  asbd.mFramesPerPacket = 1;
  asbd.mBytesPerPacket = asbd.mBytesPerFrame;
  AudioQueueRef q = NULL;
  OSStatus st = AudioQueueNewOutput(&asbd, LixhAqCallback, (__bridge void *)self, NULL,
                                    kCFRunLoopCommonModes, 0, &q);
  if (st != noErr || !q) return NO;
  UInt32 bytes = (UInt32)(useRate / 50) * asbd.mBytesPerFrame;  // ~20ms
  if (bytes < 256) bytes = 256;
  AudioQueueBufferRef bufs[3] = {0};
  for (int i = 0; i < 3; i++) {
    AudioQueueAllocateBuffer(q, bytes, &bufs[i]);
    memset(bufs[i]->mAudioData, 0, bytes);
    bufs[i]->mAudioDataByteSize = bytes;
    AudioQueueEnqueueBuffer(q, bufs[i], 0, NULL);
  }
  st = AudioQueueStart(q, NULL);
  if (st != noErr) {
    [self disposeQueue:q];
    return NO;
  }
  AudioQueueRef stale = NULL;
  BOOL ok = NO;
  @synchronized(self) {
    if (_queue) {
      // Another thread won the race — drop ours outside the lock.
      stale = q;
      ok = _started && _queue != NULL;
    } else {
      _rate = useRate;
      _ch = useCh;
      _queue = q;
      memcpy(_bufs, bufs, sizeof(bufs));
      _started = YES;
      ok = YES;
    }
  }
  [self disposeQueue:stale];
  return ok;
}

- (void)stop {
  AudioQueueRef q = NULL;
  @synchronized(self) {
    q = _queue;
    _queue = NULL;
    memset(_bufs, 0, sizeof(_bufs));
    _started = NO;
    _primed = NO;
    _r = _w = _count = 0;
  }
  [self disposeQueue:q];
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
  if (![self ensureQueueRate:sampleRate channels:channels]) return;
  @synchronized(self) {
    if (!_queue) return;
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
      int floor_ms = _maxQueueMs < 100 ? 50 : (_maxQueueMs < 140 ? 80 : 100);
      if (floor_ms > _maxQueueMs) floor_ms = _maxQueueMs;
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
