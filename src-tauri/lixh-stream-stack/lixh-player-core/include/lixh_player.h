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
enum { LIXH_EVT_STATE = 1, LIXH_EVT_ERROR = 2, LIXH_EVT_INFO = 3 };
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

typedef struct LixhStats {
    int state;
    uint64_t video_frames;
    uint64_t audio_frames;
    uint64_t dropped_frames;
    uint64_t reconnects;
    int64_t last_video_pts_ms;
    int64_t last_audio_pts_ms;
    int64_t input_buffer_ms;
    int decode_hw;
    uint64_t bytes_read;
    int video_width;
    int video_height;
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
/* When 0, video packets are discarded (audio-only / listen mode). */
void lixh_player_set_video_sink(void *p, int enabled);

#ifdef __cplusplus
}
#endif
