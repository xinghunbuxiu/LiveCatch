#import <Cocoa/Cocoa.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#include "lixh_surface.h"

typedef struct { NSView *view; AVSampleBufferDisplayLayer *layer; LixhSurfaceCallbacks cb; } LixhMacSurface;

void *lixh_surface_create(void *native_window, const LixhSurfaceCallbacks *cb) {
    if (!native_window) return NULL;
    LixhMacSurface *s = calloc(1, sizeof(*s));
    s->view = (__bridge NSView *)native_window;
    s->layer = [AVSampleBufferDisplayLayer layer];
    s->layer.videoGravity = AVLayerVideoGravityResizeAspect;
    s->layer.frame = s->view.bounds;
    [s->view setWantsLayer:YES];
    [s->view.layer addSublayer:s->layer];
    if (cb) s->cb = *cb;
    if (s->cb.on_ready) s->cb.on_ready(s->cb.opaque, s);
    return s;
}

int lixh_surface_resize(void *surface, LixhSurfaceRect rect) {
    LixhMacSurface *s = (LixhMacSurface *)surface;
    if (!s) return -1;
    dispatch_async(dispatch_get_main_queue(), ^{
        s->layer.frame = NSMakeRect(0, 0, rect.width, rect.height);
    });
    return 0;
}

int lixh_surface_present(void *surface, const LixhNativeFrame *frame, int64_t pts_ms) {
    LixhMacSurface *s = (LixhMacSurface *)surface;
    if (!s || !frame || frame->kind != LIXH_VIDEO_VIDEOTOOLBOX || !frame->handle0) return -2;
    CVPixelBufferRef pixel = (CVPixelBufferRef)frame->handle0;
    CFRetain(pixel);
    dispatch_async(dispatch_get_main_queue(), ^{
        CMVideoFormatDescriptionRef desc = NULL;
        CMSampleBufferRef sample = NULL;
        int rc = 0;
        CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pixel, &desc);
        CMTime pts = CMTimeMake(pts_ms, 1000);
        CMSampleTimingInfo timing = { .duration = kCMTimeInvalid, .presentationTimeStamp = pts, .decodeTimeStamp = kCMTimeInvalid };
        if (!desc || CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault, pixel, desc, &timing, &sample) != noErr) rc = -3;
        if (rc == 0 && sample) [s->layer enqueueSampleBuffer:sample];
        if (sample) CFRelease(sample);
        if (desc) CFRelease(desc);
        CFRelease(pixel);
        if (rc == 0 && s->cb.on_presented) s->cb.on_presented(s->cb.opaque, pts_ms);
    });
    return 0;
}

void lixh_surface_flush(void *surface) {
    LixhMacSurface *s = (LixhMacSurface *)surface;
    if (s) dispatch_sync(dispatch_get_main_queue(), ^{ [s->layer flushAndRemoveImage]; });
}

void lixh_surface_destroy(void *surface) {
    LixhMacSurface *s = (LixhMacSurface *)surface;
    if (!s) return;
    dispatch_sync(dispatch_get_main_queue(), ^{ [s->layer removeFromSuperlayer]; });
    if (s->cb.on_closed) s->cb.on_closed(s->cb.opaque);
    free(s);
}
