#pragma once
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

enum {
    LIXH_VIDEO_SOFTWARE = 0,
    LIXH_VIDEO_D3D11 = 1,
    LIXH_VIDEO_VIDEOTOOLBOX = 2,
    LIXH_VIDEO_MEDIACODEC = 3
};
enum {
    LIXH_EVT_STATE = 1,
    LIXH_EVT_ERROR = 2,
    LIXH_EVT_INFO = 3,
    /* Listen tip-batch skipped backlog — hosts should flush PCM rings. */
    LIXH_EVT_AUDIO_TIP_FLUSH = 4
};
enum { LIXH_STATE_IDLE = 0, LIXH_STATE_OPEN = 1, LIXH_STATE_PLAYING = 2, LIXH_STATE_STOPPED = 3, LIXH_STATE_ERROR = 4 };

typedef struct LixhNativeFrame {
    int kind;
    int width;
    int height;
    void *handle0;
    intptr_t handle1;
    void *owner;
} LixhNativeFrame;

typedef struct LixhCallbacks {
    void *opaque;
    int (*on_video)(void *opaque, int kind, int width, int height, int64_t pts_ms, int64_t duration_ms, const LixhNativeFrame *frame);
    void (*on_audio)(void *opaque, int sample_rate, int channels, int format, int64_t pts_ms, const float *samples, int sample_count);
    void (*on_event)(void *opaque, int type, int code, const char *message);
} LixhCallbacks;

enum {
    LIXH_PRESENT_NONE = 0,
    LIXH_PRESENT_SURFACE = 1, /* MediaCodec → Surface (zero-copy) */
    LIXH_PRESENT_RGBA = 2     /* CPU sws → ANativeWindow */
};

typedef struct LixhStats {
    int state;
    uint64_t video_frames;
    uint64_t audio_frames;
    uint64_t dropped_frames;
    uint64_t reconnects;
    int64_t last_video_pts_ms;
    int64_t last_audio_pts_ms;
    /* Clock-drift / chase backlog (wall−PTS), NOT absolute live delay.
       Absolute end-to-end latency needs a reliable wall-clock live epoch. */
    int64_t input_buffer_ms;
    int decode_hw;
    uint64_t bytes_read;
    int video_width;
    int video_height;
    /* Last successful present path: LIXH_PRESENT_*. */
    int present_mode;
    /* 0=none, 1=soft (skip present), 2=hard (skip to keyframe). */
    int chase_mode;
} LixhStats;

void *lixh_player_create(const LixhCallbacks *cb);
void lixh_player_destroy(void *p);
int lixh_player_open(void *p, const char *url);
int lixh_player_play(void *p);
void lixh_player_stop(void *p);
int lixh_player_get_stats(void *p, LixhStats *out);
/* target_ms / max_ms: catch-up / drop thresholds (ms). Pass <=0 to keep current. */
void lixh_player_set_latency(void *p, int64_t target_ms, int64_t max_ms);
/* Extra HTTP headers for avformat ("Key: Value\\r\\n..."). NULL/empty clears. */
void lixh_player_set_headers(void *p, const char *headers);
/* When 0 before open: skip video decoder (listen-first). When toggled on
   while playing, decoder is opened on the play thread. Packets are discarded
   while sink is 0. */
void lixh_player_set_video_sink(void *p, int enabled);
/* Max audio catch-up rate (1.0 = off). Actual rate adapts to clock drift;
   listen often uses 1.3 as the ceiling. Clamped to ~1.0–1.5. */
void lixh_player_set_play_rate(void *p, float rate);
/* Android only: jobject Surface for MediaCodec zero-copy output.
   Pass NULL to clear. Must be set before open (or after stop, before re-open).
   Ownership of the JNI GlobalRef stays with the caller. */
void lixh_player_set_android_surface(void *p, void *surface);

#ifdef __cplusplus
}
#endif
