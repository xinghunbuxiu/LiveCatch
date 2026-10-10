#import "LixhPixelTexture.h"

@implementation LixhPixelTexture {
  CVPixelBufferRef _latest;
}

- (void)dealloc {
  if (_latest) CFRelease(_latest);
}

- (void)setPixelBuffer:(CVPixelBufferRef)buffer {
  if (!buffer) return;
  CFRetain(buffer);
  CVPixelBufferRef old = _latest;
  _latest = buffer;
  if (old) CFRelease(old);
}

- (void)presentColorR:(float)r g:(float)g b:(float)b width:(int)width height:(int)height {
  if (width < 2) width = 64;
  if (height < 2) height = 64;
  NSDictionary *attrs = @{
    (id)kCVPixelBufferIOSurfacePropertiesKey : @{},
    (id)kCVPixelBufferCGImageCompatibilityKey : @YES,
    (id)kCVPixelBufferCGBitmapContextCompatibilityKey : @YES,
  };
  CVPixelBufferRef pix = NULL;
  if (CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                          kCVPixelFormatType_32BGRA,
                          (__bridge CFDictionaryRef)attrs, &pix) != kCVReturnSuccess) {
    return;
  }
  CVPixelBufferLockBaseAddress(pix, 0);
  uint8_t *base = CVPixelBufferGetBaseAddress(pix);
  size_t stride = CVPixelBufferGetBytesPerRow(pix);
  uint8_t B = (uint8_t)(b * 255.f), G = (uint8_t)(g * 255.f), R = (uint8_t)(r * 255.f);
  for (int y = 0; y < height; y++) {
    uint8_t *row = base + (size_t)y * stride;
    for (int x = 0; x < width; x++) {
      row[x * 4 + 0] = B;
      row[x * 4 + 1] = G;
      row[x * 4 + 2] = R;
      row[x * 4 + 3] = 255;
    }
  }
  CVPixelBufferUnlockBaseAddress(pix, 0);
  [self setPixelBuffer:pix];
  CFRelease(pix);
}

- (CVPixelBufferRef)copyPixelBuffer {
  CVPixelBufferRef buf = _latest;
  if (!buf) return NULL;
  CFRetain(buf);
  return buf;
}

@end
