#import <Cocoa/Cocoa.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#include <libavutil/frame.h>
#include <libavutil/pixfmt.h>
#include "lixh_surface.h"

typedef struct { NSView *view; AVSampleBufferDisplayLayer *layer; LixhSurfaceCallbacks cb; } LixhMacSurface;

// Upload a software AVFrame into a new CVPixelBuffer (caller owns one ref).
// Supports the two formats live H264/AAC streams actually produce.
static CVPixelBufferRef LixhUploadSoftwareFrame(const AVFrame *f) {
    if (!f || f->width <= 0 || f->height <= 0 || !f->data[0]) return NULL;
    OSType cvfmt = 0;
    if (f->format == AV_PIX_FMT_YUV420P) cvfmt = kCVPixelFormatType_420YpCbCr8Planar;
    else if (f->format == AV_PIX_FMT_NV12) cvfmt = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
    else return NULL;
    CVPixelBufferRef pix = NULL;
    if (CVPixelBufferCreate(kCFAllocatorDefault, f->width, f->height, cvfmt, NULL, &pix) != kCVReturnSuccess) return NULL;
    CVPixelBufferLockBaseAddress(pix, 0);
    int ok = 0;
    do {
        int cw = (f->width + 1) / 2, ch = (f->height + 1) / 2;
        uint8_t *d0 = CVPixelBufferGetBaseAddressOfPlane(pix, 0);
        size_t rb0 = CVPixelBufferGetBytesPerRowOfPlane(pix, 0);
        if (!d0) break;
        for (int y = 0; y < f->height; y++)
            memcpy(d0 + (size_t)y * rb0, f->data[0] + (size_t)y * f->linesize[0], (size_t)f->width);
        uint8_t *d1 = CVPixelBufferGetBaseAddressOfPlane(pix, 1);
        size_t rb1 = CVPixelBufferGetBytesPerRowOfPlane(pix, 1);
        if (!d1) break;
        if (f->format == AV_PIX_FMT_YUV420P) {
            uint8_t *d2 = CVPixelBufferGetBaseAddressOfPlane(pix, 2);
            size_t rb2 = CVPixelBufferGetBytesPerRowOfPlane(pix, 2);
            if (!d2) break;
            for (int y = 0; y < ch; y++) {
                memcpy(d1 + (size_t)y * rb1, f->data[1] + (size_t)y * f->linesize[1], (size_t)cw);
                memcpy(d2 + (size_t)y * rb2, f->data[2] + (size_t)y * f->linesize[2], (size_t)cw);
            }
        } else {
            for (int y = 0; y < ch; y++)
                memcpy(d1 + (size_t)y * rb1, f->data[1] + (size_t)y * f->linesize[1], (size_t)cw * 2);
        }
        ok = 1;
    } while (0);
    CVPixelBufferUnlockBaseAddress(pix, 0);
    if (!ok) { CFRelease(pix); return NULL; }
    return pix;
}

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
    double x = rect.x, y = rect.y, w = rect.width, h = rect.height;
    CGFloat vh0 = s->view.bounds.size.height;
    NSLog(@"[lixh-surface] dock x=%.1f y=%.1f w=%.1f h=%.1f viewH=%.1f -> layerY=%.1f",
          x, y, w, h, vh0, vh0 - y - h);
    dispatch_async(dispatch_get_main_queue(), ^{
        // DOM origin is top-left, CALayer origin is bottom-left:
        // flip Y against the webview height so the picture lands in the hole.
        CGFloat vh = s->view.bounds.size.height;
        s->layer.frame = NSMakeRect(x, vh - y - h, w, h);
    });
    return 0;
}

int lixh_surface_present(void *surface, const LixhNativeFrame *frame, int64_t pts_ms) {
    LixhMacSurface *s = (LixhMacSurface *)surface;
    if (!s || !frame || !frame->handle0) return -2;
    CVPixelBufferRef pixel = NULL;
    if (frame->kind == LIXH_VIDEO_VIDEOTOOLBOX) {
        pixel = (CVPixelBufferRef)frame->handle0;
        CFRetain(pixel);
    } else if (frame->kind == LIXH_VIDEO_SOFTWARE) {
        pixel = LixhUploadSoftwareFrame((const AVFrame *)frame->handle0);
        if (!pixel) return -4;
    } else {
        return -2;
    }
    static int n = 0;
    if ((++n % 300) == 1) NSLog(@"[lixh-surface] present #%d kind=%d %dx%d", n, frame->kind, frame->width, frame->height);
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
