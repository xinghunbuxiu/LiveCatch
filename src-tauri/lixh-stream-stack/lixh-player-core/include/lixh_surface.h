#pragma once
#include <stdint.h>
#include "lixh_player.h"
#ifdef __cplusplus
extern "C" {
#endif

typedef struct LixhSurfaceRect { double x, y, width, height, device_scale; } LixhSurfaceRect;

typedef struct LixhSurfaceCallbacks {
    void *opaque;
    void (*on_ready)(void *opaque, void *native_surface);
    void (*on_presented)(void *opaque, int64_t pts_ms);
    void (*on_closed)(void *opaque);
} LixhSurfaceCallbacks;

void *lixh_surface_create(void *native_window, const LixhSurfaceCallbacks *cb);
void lixh_surface_destroy(void *surface);
int lixh_surface_resize(void *surface, LixhSurfaceRect rect);
int lixh_surface_present(void *surface, const LixhNativeFrame *frame, int64_t pts_ms);
void lixh_surface_flush(void *surface);
#ifdef __cplusplus
}
#endif