#include "lixh_player.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdatomic.h>
#include <inttypes.h>
#include <time.h>

#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/avutil.h>
#include <libavutil/opt.h>
#include <libavutil/time.h>
#include <libavutil/hwcontext.h>
#include <libavutil/frame.h>
#include <libavutil/channel_layout.h>
#include <libswresample/swresample.h>

#ifdef LIXH_WINDOWS
#include <libavutil/hwcontext_d3d11va.h>
#include <d3d11.h>
#endif
#if defined(LIXH_MACOS) || defined(LIXH_IOS)
#include <libavutil/hwcontext_videotoolbox.h>
#endif
#if defined(LIXH_ANDROID)
#include <libavcodec/mediacodec.h>
#endif

/* ---- portable sync (demux ∥ audio decode ∥ video decode) ---- */
#if defined(LIXH_WINDOWS)
#include <windows.h>
typedef HANDLE lixh_thread_t;
typedef CRITICAL_SECTION lixh_mutex_t;
typedef CONDITION_VARIABLE lixh_cond_t;
typedef struct { void *(*fn)(void *); void *arg; } LixhWinThreadArg;
static DWORD WINAPI lixh_win_trampoline(void *p) {
    LixhWinThreadArg *a = (LixhWinThreadArg *)p;
    void *(*fn)(void *) = a->fn;
    void *arg = a->arg;
    free(a);
    fn(arg);
    return 0;
}
static int lixh_thread_create(lixh_thread_t *t, void *(*fn)(void *), void *arg) {
    LixhWinThreadArg *a = (LixhWinThreadArg *)malloc(sizeof(*a));
    if (!a) return -1;
    a->fn = fn; a->arg = arg;
    *t = CreateThread(NULL, 0, lixh_win_trampoline, a, 0, NULL);
    if (!*t) { free(a); return -1; }
    return 0;
}
static void lixh_thread_join(lixh_thread_t t) {
    if (t) { WaitForSingleObject(t, INFINITE); CloseHandle(t); }
}
static void lixh_mutex_init(lixh_mutex_t *m) { InitializeCriticalSection(m); }
static void lixh_mutex_destroy(lixh_mutex_t *m) { DeleteCriticalSection(m); }
static void lixh_mutex_lock(lixh_mutex_t *m) { EnterCriticalSection(m); }
static void lixh_mutex_unlock(lixh_mutex_t *m) { LeaveCriticalSection(m); }
static void lixh_cond_init(lixh_cond_t *c) { InitializeConditionVariable(c); }
static void lixh_cond_destroy(lixh_cond_t *c) { (void)c; }
static void lixh_cond_signal(lixh_cond_t *c) { WakeConditionVariable(c); }
static void lixh_cond_broadcast(lixh_cond_t *c) { WakeAllConditionVariable(c); }
static void lixh_cond_wait_ms(lixh_cond_t *c, lixh_mutex_t *m, int ms) {
    SleepConditionVariableCS(c, m, ms > 0 ? (DWORD)ms : 1);
}
#else
#include <pthread.h>
typedef pthread_t lixh_thread_t;
typedef pthread_mutex_t lixh_mutex_t;
typedef pthread_cond_t lixh_cond_t;
static int lixh_thread_create(lixh_thread_t *t, void *(*fn)(void *), void *arg) {
    return pthread_create(t, NULL, fn, arg) == 0 ? 0 : -1;
}
static void lixh_thread_join(lixh_thread_t t) { pthread_join(t, NULL); }
static void lixh_mutex_init(lixh_mutex_t *m) { pthread_mutex_init(m, NULL); }
static void lixh_mutex_destroy(lixh_mutex_t *m) { pthread_mutex_destroy(m); }
static void lixh_mutex_lock(lixh_mutex_t *m) { pthread_mutex_lock(m); }
static void lixh_mutex_unlock(lixh_mutex_t *m) { pthread_mutex_unlock(m); }
static void lixh_cond_init(lixh_cond_t *c) { pthread_cond_init(c, NULL); }
static void lixh_cond_destroy(lixh_cond_t *c) { pthread_cond_destroy(c); }
static void lixh_cond_signal(lixh_cond_t *c) { pthread_cond_signal(c); }
static void lixh_cond_broadcast(lixh_cond_t *c) { pthread_cond_broadcast(c); }
static void lixh_cond_wait_ms(lixh_cond_t *c, lixh_mutex_t *m, int ms) {
    if (ms <= 0) { pthread_cond_wait(c, m); return; }
    struct timespec ts;
#if defined(CLOCK_REALTIME)
    clock_gettime(CLOCK_REALTIME, &ts);
#else
    ts.tv_sec = time(NULL); ts.tv_nsec = 0;
#endif
    ts.tv_sec += ms / 1000;
    ts.tv_nsec += (long)(ms % 1000) * 1000000L;
    if (ts.tv_nsec >= 1000000000L) { ts.tv_sec++; ts.tv_nsec -= 1000000000L; }
    pthread_cond_timedwait(c, m, &ts);
}
#endif

/* Audio pktq ~150ms — absorb demux jitter without multi-second lag. */
enum { LIXH_AQ_MAX_MS = 150, LIXH_VQ_MAX_MS = 300, LIXH_AQ_MAX_N = 56, LIXH_VQ_MAX_N = 90 };

typedef struct LixhPktQ {
    AVPacket **pkts;
    int cap, r, w, n;
    int64_t oldest_pts_ms, newest_pts_ms;
    int max_ms, max_n, is_video;
    lixh_mutex_t mu;
    lixh_cond_t can_pop;
    int closed;
    int inited;
} LixhPktQ;

static int64_t pkt_pts_ms(const AVPacket *pkt, AVRational tb) {
    if (!pkt || pkt->pts == AV_NOPTS_VALUE) return AV_NOPTS_VALUE;
    return av_rescale_q(pkt->pts, tb, (AVRational){1, 1000});
}

static int pktq_init(LixhPktQ *q, int is_video) {
    memset(q, 0, sizeof(*q));
    q->is_video = is_video;
    q->max_ms = is_video ? LIXH_VQ_MAX_MS : LIXH_AQ_MAX_MS;
    q->max_n = is_video ? LIXH_VQ_MAX_N : LIXH_AQ_MAX_N;
    q->cap = q->max_n + 4;
    q->pkts = (AVPacket **)calloc((size_t)q->cap, sizeof(AVPacket *));
    if (!q->pkts) return -1;
    for (int i = 0; i < q->cap; ++i) {
        q->pkts[i] = av_packet_alloc();
        if (!q->pkts[i]) return -1;
    }
    q->oldest_pts_ms = q->newest_pts_ms = AV_NOPTS_VALUE;
    lixh_mutex_init(&q->mu);
    lixh_cond_init(&q->can_pop);
    q->inited = 1;
    return 0;
}

static void pktq_clear_locked(LixhPktQ *q) {
    while (q->n > 0) {
        av_packet_unref(q->pkts[q->r]);
        q->r = (q->r + 1) % q->cap;
        q->n--;
    }
    q->oldest_pts_ms = q->newest_pts_ms = AV_NOPTS_VALUE;
}

static void pktq_close(LixhPktQ *q) {
    if (!q || !q->inited) return;
    lixh_mutex_lock(&q->mu);
    q->closed = 1;
    lixh_cond_broadcast(&q->can_pop);
    lixh_mutex_unlock(&q->mu);
}

static void pktq_reopen(LixhPktQ *q) {
    if (!q || !q->inited) return;
    lixh_mutex_lock(&q->mu);
    pktq_clear_locked(q);
    q->closed = 0;
    lixh_mutex_unlock(&q->mu);
}

static void pktq_destroy(LixhPktQ *q) {
    if (!q || !q->inited) return;
    lixh_mutex_lock(&q->mu);
    q->closed = 1;
    pktq_clear_locked(q);
    lixh_cond_broadcast(&q->can_pop);
    lixh_mutex_unlock(&q->mu);
    for (int i = 0; i < q->cap; ++i) {
        if (q->pkts[i]) av_packet_free(&q->pkts[i]);
    }
    free(q->pkts);
    q->pkts = NULL;
    lixh_cond_destroy(&q->can_pop);
    lixh_mutex_destroy(&q->mu);
    q->inited = 0;
}

static int pktq_span_ms_locked(LixhPktQ *q) {
    if (q->n <= 0 || q->oldest_pts_ms == AV_NOPTS_VALUE || q->newest_pts_ms == AV_NOPTS_VALUE)
        return 0;
    int64_t s = q->newest_pts_ms - q->oldest_pts_ms;
    return s > 0 ? (int)s : 0;
}

static void pktq_refresh_oldest_locked(LixhPktQ *q) {
    if (q->n <= 0) {
        q->oldest_pts_ms = AV_NOPTS_VALUE;
        return;
    }
    /* meta in pkt->opaque is awkward; use dts/pts rescaled at push into side_data-less field:
       we stash pts_ms in pkt->pos (unused for live FLV network). */
    q->oldest_pts_ms = q->pkts[q->r]->pos;
}

static int pktq_push(LixhPktQ *q, AVPacket *src, int64_t pts_ms, int is_key, atomic_uint_fast64_t *dropped) {
    if (!q || !q->inited || !src) return -1;
    lixh_mutex_lock(&q->mu);
    if (q->closed) { lixh_mutex_unlock(&q->mu); return -1; }
    /* Live edge: never block demux — drop oldest when fat. */
    while (q->n > 0 && (q->n >= q->max_n || pktq_span_ms_locked(q) > q->max_ms)) {
        if (q->is_video) {
            /* Drop until a keyframe at head or queue thin enough. */
            int dropped_key_hunt = 0;
            while (q->n > 1) {
                pktq_refresh_oldest_locked(q);
                int head_key = (q->pkts[q->r]->flags & AV_PKT_FLAG_KEY) != 0;
                if (head_key && pktq_span_ms_locked(q) <= q->max_ms && q->n < q->max_n)
                    break;
                av_packet_unref(q->pkts[q->r]);
                q->r = (q->r + 1) % q->cap;
                q->n--;
                dropped_key_hunt = 1;
                if (dropped) atomic_fetch_add_explicit(dropped, 1, memory_order_relaxed);
                pktq_refresh_oldest_locked(q);
                if (q->n > 0 && (q->pkts[q->r]->flags & AV_PKT_FLAG_KEY) &&
                    pktq_span_ms_locked(q) <= q->max_ms)
                    break;
                if (q->n < q->max_n / 2) break;
            }
            if (!dropped_key_hunt && q->n >= q->max_n) {
                av_packet_unref(q->pkts[q->r]);
                q->r = (q->r + 1) % q->cap;
                q->n--;
                if (dropped) atomic_fetch_add_explicit(dropped, 1, memory_order_relaxed);
            }
            pktq_refresh_oldest_locked(q);
        } else {
            av_packet_unref(q->pkts[q->r]);
            q->r = (q->r + 1) % q->cap;
            q->n--;
            if (dropped) atomic_fetch_add_explicit(dropped, 1, memory_order_relaxed);
            pktq_refresh_oldest_locked(q);
        }
    }
    if (q->n >= q->cap) { lixh_mutex_unlock(&q->mu); return -1; }
    av_packet_unref(q->pkts[q->w]);
    av_packet_move_ref(q->pkts[q->w], src);
    /* stash pts_ms in pos for span tracking */
    q->pkts[q->w]->pos = pts_ms;
    if (is_key) q->pkts[q->w]->flags |= AV_PKT_FLAG_KEY;
    if (q->n == 0) q->oldest_pts_ms = pts_ms;
    if (pts_ms != AV_NOPTS_VALUE) q->newest_pts_ms = pts_ms;
    q->w = (q->w + 1) % q->cap;
    q->n++;
    lixh_cond_signal(&q->can_pop);
    lixh_mutex_unlock(&q->mu);
    return 0;
}

/* returns 1=got packet, 0=closed/stop empty, -1=error */
static int pktq_pop(LixhPktQ *q, AVPacket *dst, atomic_int *stop) {
    if (!q || !q->inited || !dst) return -1;
    lixh_mutex_lock(&q->mu);
    for (;;) {
        if (q->n > 0) {
            av_packet_unref(dst);
            av_packet_move_ref(dst, q->pkts[q->r]);
            q->r = (q->r + 1) % q->cap;
            q->n--;
            pktq_refresh_oldest_locked(q);
            lixh_mutex_unlock(&q->mu);
            return 1;
        }
        if (q->closed || (stop && atomic_load_explicit(stop, memory_order_acquire))) {
            lixh_mutex_unlock(&q->mu);
            return 0;
        }
        lixh_cond_wait_ms(&q->can_pop, &q->mu, 30);
    }
}


typedef struct LixhPlayer {
    LixhCallbacks cb;
    AVFormatContext *fmt;
    AVCodecContext *vdec;
    AVCodecContext *adec;
    AVBufferRef *hw_device;
    SwrContext *swr;
    AVFrame *audio_frame;
    AVFrame *video_frame;
    AVFrame *transfer_frame;
    float *audio_out;
    size_t audio_out_capacity;
    int vstream;
    int astream;
    enum AVPixelFormat hw_pix_fmt;
    int hw_kind;
    atomic_int state;
    atomic_int stop;
    atomic_int playing;
    /* 0 = probe direct D3D11 presentation, 1 = working, -1 = use transfer fallback. */
    atomic_int direct_d3d11;
    /* 1 = decode+deliver video; 0 = drop video packets (listen-only). */
    atomic_int video_sink;
    /* Set from UI thread; consumed only on the play/decode thread. */
    atomic_int flush_video_req;
    /* Listen→picture: open video decoder on the play thread (never from UI). */
    atomic_int open_video_req;
    atomic_int present_mode;
    int opened;
    char *url;
    char *http_headers;
#if defined(LIXH_ANDROID)
    /* Opaque jobject Surface (caller-owned GlobalRef). */
    void *android_surface;
    int mc_surface_inited;
#endif
    /* Video chase anchors — never written by the audio path. */
    atomic_int_fast64_t video_anchor_pts_ms;
    atomic_int_fast64_t video_anchor_wall_ms;
    /* Audio clock-drift anchors — stats only; do not drive video chase. */
    atomic_int_fast64_t audio_anchor_pts_ms;
    atomic_int_fast64_t audio_anchor_wall_ms;
    atomic_int_fast64_t last_video_pts_ms;
    atomic_int_fast64_t last_audio_pts_ms;
    atomic_int_fast64_t latest_video_pkt_pts_ms;
    atomic_uint_fast64_t video_frames;
    atomic_uint_fast64_t audio_frames;
    atomic_uint_fast64_t dropped_frames;
    atomic_uint_fast64_t reconnects;
    atomic_uint_fast64_t bytes_read;
    atomic_int video_width;
    atomic_int video_height;
    int64_t target_latency_ms;
    int64_t max_latency_ms;
    /* 0=none, 1=soft (continuous skip present), 2=hard (flush + skip to tip). */
    int chase_mode;
    /* Video-thread flush request after entering CHASE_HARD (also UI-safe). */
    atomic_int chase_need_flush;
    /* After listen→picture: present every frame briefly (no chase drops). */
    int64_t video_join_grace_until_ms;
    /* Platform PCM queue depth (ms). -1 = not reported → drift fallback. */
    atomic_int audio_out_queue_ms;
    /* Consecutive on_video <0 before committing to demux-thread SW download. */
    int d3d11_fail_streak;
    int sample_rate;
    int channels;
    /* Audio play rate ×1000 (1000=1.0x). Listen catch-up often ~1300. */
    atomic_int play_rate_milli;
    /* Last applied rate — hysteresis so speech doesn't warble 1.0↔1.3. */
    int rate_milli_applied;
    float *audio_speed;
    size_t audio_speed_capacity;
    /* Demux ∥ A/V decode pipeline (owned by play()). */
    LixhPktQ aq;
    LixhPktQ vq;
    lixh_thread_t audio_th;
    lixh_thread_t video_th;
    int workers_up;
    /* Serializes vdec open/flush vs video decode thread. */
    lixh_mutex_t vdec_mu;
    int vdec_mu_inited;
} LixhPlayer;

static void emit(LixhPlayer *p, int type, int code, const char *msg) {
    if (p && p->cb.on_event) p->cb.on_event(p->cb.opaque, type, code, msg ? msg : "");
}

static int64_t now_ms(void) { return av_gettime_relative() / 1000; }

static int interrupt_cb(void *opaque) {
    LixhPlayer *p = (LixhPlayer *)opaque;
    return p && atomic_load_explicit(&p->stop, memory_order_acquire) ? 1 : 0;
}

#if defined(LIXH_ANDROID)
static void free_mediacodec_surface(LixhPlayer *p) {
    if (p->mc_surface_inited && p->vdec) {
        av_mediacodec_default_free(p->vdec);
    }
    p->mc_surface_inited = 0;
}

static void release_mc_buffer(AVFrame *f, int render) {
    if (!f || f->format != AV_PIX_FMT_MEDIACODEC || !f->data[3]) return;
    av_mediacodec_release_buffer((AVMediaCodecBuffer *)f->data[3], render ? 1 : 0);
}
#endif

static void free_player_media(LixhPlayer *p) {
    av_freep(&p->audio_speed);
    p->audio_speed_capacity = 0;
    if (p->swr) swr_free(&p->swr);
#if defined(LIXH_ANDROID)
    free_mediacodec_surface(p);
#endif
    if (p->vdec) avcodec_free_context(&p->vdec);
    if (p->adec) avcodec_free_context(&p->adec);
    if (p->fmt) avformat_close_input(&p->fmt);
    if (p->hw_device) av_buffer_unref(&p->hw_device);
    if (p->audio_frame) av_frame_free(&p->audio_frame);
    if (p->video_frame) av_frame_free(&p->video_frame);
    if (p->transfer_frame) av_frame_free(&p->transfer_frame);
    av_freep(&p->audio_out);
    p->audio_out_capacity = 0;
    p->vstream = p->astream = -1;
    p->opened = 0;
}

static enum AVPixelFormat choose_hw_format(AVCodecContext *ctx, const enum AVPixelFormat *fmts) {
    LixhPlayer *p = (LixhPlayer *)ctx->opaque;
    for (const enum AVPixelFormat *f = fmts; *f != AV_PIX_FMT_NONE; ++f) {
        if (*f == p->hw_pix_fmt) return *f;
    }
    /* The decoder refused the hardware format: log why, since open2 still
       succeeds and the only other symptom is a silent CPU fallback. */
    emit(p, LIXH_EVT_INFO, fmts[0], "mediacodec format rejected; first offered");
    p->hw_kind = LIXH_VIDEO_SOFTWARE;
    return fmts[0];
}

static int setup_hw(LixhPlayer *p) {
#if defined(LIXH_WINDOWS)
    enum AVHWDeviceType type = AV_HWDEVICE_TYPE_D3D11VA;
    p->hw_pix_fmt = AV_PIX_FMT_D3D11;
    p->hw_kind = LIXH_VIDEO_D3D11;
    int rc = av_hwdevice_ctx_create(&p->hw_device, type, NULL, NULL, 0);
    if (rc < 0) {
        p->hw_device = NULL;
        p->hw_kind = LIXH_VIDEO_SOFTWARE;
        return rc;
    }
    return 0;
#elif defined(LIXH_ANDROID)
    /* MediaCodec → Surface when android_surface is set; else transfer→RGBA. */
    p->hw_pix_fmt = AV_PIX_FMT_MEDIACODEC;
    p->hw_kind = LIXH_VIDEO_MEDIACODEC;
    /* Deferred picture-open calls this again for the same session; reuse the
       device instead of leaking one per open and re-running the probe. */
    if (p->hw_device) return 0;
    int rc = av_hwdevice_ctx_create(&p->hw_device, AV_HWDEVICE_TYPE_MEDIACODEC, NULL, NULL, 0);
    if (rc < 0) {
        p->hw_device = NULL;
        p->hw_kind = LIXH_VIDEO_SOFTWARE;
        emit(p, LIXH_EVT_INFO, rc, "mediacodec device create failed; software decode");
        return rc;
    }
    return 0;
#else
    /* macOS/iOS: software first; VT wired in platform engines when available. */
    p->hw_device = NULL;
    p->hw_kind = LIXH_VIDEO_SOFTWARE;
    return 0;
#endif
}

#if defined(LIXH_ANDROID)
/* MediaCodec decoders are separate codec entries named "<codec>_mediacodec"
 * (ff_h264_mediacodec_decoder, ff_hevc_mediacodec_decoder, ...), not a mode of
 * the software decoder. Resolve the name from the codec descriptor so new
 * codecs need no table here, and return NULL when this build lacks that entry
 * so the caller can fall back to software. */
static const AVCodec *find_mediacodec_decoder(enum AVCodecID id) {
    const AVCodecDescriptor *desc = avcodec_descriptor_get(id);
    if (!desc || !desc->name) return NULL;
    char name[64];
    int n = snprintf(name, sizeof(name), "%s_mediacodec", desc->name);
    if (n <= 0 || (size_t)n >= sizeof(name)) return NULL;
    return avcodec_find_decoder_by_name(name);
}
#endif

static int open_decoder(LixhPlayer *p, AVStream *st, int video) {
    const AVCodec *codec = NULL;
    /* Hardware first when a Surface is available; software fallback below. */
#if defined(LIXH_ANDROID)
    if (video && p->hw_device && p->android_surface) {
        codec = find_mediacodec_decoder(st->codecpar->codec_id);
        if (!codec) {
            emit(p, LIXH_EVT_INFO, (int)st->codecpar->codec_id,
                 "no mediacodec decoder for this codec; software video");
        }
    }
#endif
    if (!codec) codec = avcodec_find_decoder(st->codecpar->codec_id);
    if (!codec) return AVERROR_DECODER_NOT_FOUND;
    AVCodecContext *ctx = avcodec_alloc_context3(codec);
    if (!ctx) return AVERROR(ENOMEM);
    int rc = avcodec_parameters_to_context(ctx, st->codecpar);
    if (rc < 0) { avcodec_free_context(&ctx); return rc; }
    ctx->opaque = p;
    ctx->thread_count = 0;
    if (video) {
        ctx->flags |= AV_CODEC_FLAG_LOW_DELAY;
        ctx->flags2 |= AV_CODEC_FLAG2_FAST;
        if (p->hw_device) {
            ctx->get_format = choose_hw_format;
            ctx->hw_device_ctx = av_buffer_ref(p->hw_device);
            ctx->thread_count = 1;
        }
#if defined(LIXH_ANDROID)
        /* Bind Flutter SurfaceTexture before open for zero-copy output. */
        if (!p->hw_device) {
            emit(p, LIXH_EVT_INFO, 0, "no hw device; software video");
        } else if (!p->android_surface) {
            emit(p, LIXH_EVT_INFO, 0, "no android surface; mediacodec will transfer");
        } else {
            AVMediaCodecContext *mc = av_mediacodec_alloc_context();
            if (!mc) {
                emit(p, LIXH_EVT_INFO, 0, "av_mediacodec_alloc_context failed");
            } else {
                int mrc = av_mediacodec_default_init(ctx, mc, p->android_surface);
                if (mrc == 0) {
                    p->mc_surface_inited = 1;
                } else {
                    emit(p, LIXH_EVT_INFO, mrc, "av_mediacodec_default_init failed");
                }
            }
        }
#endif
        rc = avcodec_open2(ctx, codec, NULL);
        if (rc < 0 && p->hw_device) {
#if defined(LIXH_ANDROID)
            if (p->mc_surface_inited) {
                av_mediacodec_default_free(ctx);
                p->mc_surface_inited = 0;
            }
#endif
            av_buffer_unref(&ctx->hw_device_ctx);
            p->hw_kind = LIXH_VIDEO_SOFTWARE;
            ctx->get_format = NULL;
            emit(p, LIXH_EVT_INFO, rc, "hw open failed; software video");
            rc = avcodec_open2(ctx, codec, NULL);
        }
    } else {
        /* Audio: single-thread + low delay — AAC frame threading adds join lag. */
        ctx->flags |= AV_CODEC_FLAG_LOW_DELAY;
        ctx->flags2 |= AV_CODEC_FLAG2_FAST;
        ctx->thread_count = 1;
        rc = avcodec_open2(ctx, codec, NULL);
    }
    if (rc < 0) {
#if defined(LIXH_ANDROID)
        if (p->mc_surface_inited) {
            av_mediacodec_default_free(ctx);
            p->mc_surface_inited = 0;
        }
#endif
        avcodec_free_context(&ctx);
        return rc;
    }
    if (video) p->vdec = ctx; else p->adec = ctx;
    return 0;
}

/* Probe budget per attempt. The tight tier joins fast on healthy FLV/RTSP
   edges; the wide tier is the safety net for streams whose SPS/PPS or AAC
   config sits further into the file (some Douyin rungs, HLS-fMP4, odd AAC
   profiles). Without the fallback such a stream failed to open outright and
   surfaced as "open_failed / stream not found" with no recovery. */
typedef struct {
    int probesize;
    int analyzeduration_ms;
} LixhProbeBudget;

static void probe_budgets(LixhPlayer *p, LixhProbeBudget out[2]) {
    int want_video = atomic_load_explicit(&p->video_sink, memory_order_acquire);
    /* Listen-only carries no video decoder, so the tight tier is genuinely
       cheap; picture needs room for the first keyframe + codec extradata. */
    out[0].probesize = want_video ? 163840 : 65536;
    out[0].analyzeduration_ms = want_video ? 150000 : 120000;
    out[1].probesize = want_video ? 1000000 : 524288;
    out[1].analyzeduration_ms = want_video ? 600000 : 400000;
}

static int open_input_once(LixhPlayer *p, const LixhProbeBudget *budget) {
    AVDictionary *opts = NULL;
    /* Keep lean, but avoid seekable=0 / avioflags=direct — those break some
       Douyin only_audio FLV joins (open_failed / stream not found). */
    av_dict_set(&opts, "fflags", "nobuffer+discardcorrupt+flush_packets", 0);
    av_dict_set(&opts, "max_delay", "0", 0);
    av_dict_set(&opts, "flags", "low_delay", 0);
    char num[32];
    snprintf(num, sizeof(num), "%d", budget->probesize);
    av_dict_set(&opts, "probesize", num, 0);
    snprintf(num, sizeof(num), "%d", budget->analyzeduration_ms);
    av_dict_set(&opts, "analyzeduration", num, 0);
    av_dict_set(&opts, "rw_timeout", "2500000", 0);
    av_dict_set(&opts, "timeout", "2500000", 0);
    /* Live CDN edge nodes (e.g. douyincdn) throttle/reset bare Lavf
       clients mid-stream, which desyncs the FLV demuxer. Pose as a
       browser to get a stable connection. */
    av_dict_set(&opts, "user_agent", "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36", 0);
    if (p->http_headers && p->http_headers[0]) {
        av_dict_set(&opts, "headers", p->http_headers, 0);
    } else {
        av_dict_set(&opts, "headers", "Referer: https://live.douyin.com/\r\nAccept: */*\r\n", 0);
    }
    av_dict_set(&opts, "reconnect", "1", 0);
    av_dict_set(&opts, "reconnect_streamed", "1", 0);
    av_dict_set(&opts, "reconnect_delay_max", "2", 0);
    int rc = avformat_open_input(&p->fmt, p->url, NULL, &opts);
    av_dict_free(&opts);
    if (rc < 0) return rc;
    p->fmt->flags |= AVFMT_FLAG_NOBUFFER;
    p->fmt->interrupt_callback.callback = interrupt_cb;
    p->fmt->interrupt_callback.opaque = p;
    return avformat_find_stream_info(p->fmt, NULL);
}

static int open_input(LixhPlayer *p) {
    static int net_inited;
    if (!net_inited) {
        avformat_network_init();
        net_inited = 1;
    }
    LixhProbeBudget budgets[2];
    probe_budgets(p, budgets);
    int rc = open_input_once(p, &budgets[0]);
    if (rc < 0) {
        /* Reopen from scratch: a failed probe can leave a half-read demuxer. */
        if (p->fmt) avformat_close_input(&p->fmt);
        char detail[96];
        snprintf(detail, sizeof(detail), "probe retry (probe=%d analyze=%dms) after %d",
                 budgets[1].probesize, budgets[1].analyzeduration_ms, rc);
        emit(p, LIXH_EVT_INFO, rc, detail);
        rc = open_input_once(p, &budgets[1]);
    }
    if (rc < 0) return rc;
    p->vstream = av_find_best_stream(p->fmt, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
    p->astream = av_find_best_stream(p->fmt, AVMEDIA_TYPE_AUDIO, -1, -1, NULL, 0);
    int want_video = atomic_load_explicit(&p->video_sink, memory_order_acquire);
    if (want_video) {
        if (p->vstream < 0) return AVERROR_STREAM_NOT_FOUND;
        setup_hw(p);
        rc = open_decoder(p, p->fmt->streams[p->vstream], 1);
        if (rc < 0) return rc;
    } else {
        /* Listen-only: require audio; skip video decoder/HW (big Android win).
           Discard video at demux so we don't pay to parse FLV video tags. */
        if (p->astream < 0) return AVERROR_STREAM_NOT_FOUND;
        if (p->vstream >= 0) {
            p->fmt->streams[p->vstream]->discard = AVDISCARD_ALL;
        }
        atomic_store_explicit(&p->open_video_req, 0, memory_order_release);
    }
    if (p->astream >= 0) {
        rc = open_decoder(p, p->fmt->streams[p->astream], 0);
        if (rc < 0) p->astream = -1;
    }
    if (!want_video && p->astream < 0) return AVERROR_STREAM_NOT_FOUND;
    if (p->adec) {
        p->sample_rate = p->adec->sample_rate;
        p->channels = p->adec->ch_layout.nb_channels;
        p->swr = swr_alloc();
        if (p->swr) {
            AVChannelLayout out = p->adec->ch_layout;
            av_opt_set_chlayout(p->swr, "in_chlayout", &p->adec->ch_layout, 0);
            av_opt_set_chlayout(p->swr, "out_chlayout", &out, 0);
            av_opt_set_int(p->swr, "in_sample_rate", p->adec->sample_rate, 0);
            av_opt_set_int(p->swr, "out_sample_rate", p->adec->sample_rate, 0);
            av_opt_set_sample_fmt(p->swr, "in_sample_fmt", p->adec->sample_fmt, 0);
            av_opt_set_sample_fmt(p->swr, "out_sample_fmt", AV_SAMPLE_FMT_FLT, 0);
            if (swr_init(p->swr) < 0) swr_free(&p->swr);
        }
    }
    p->opened = 1;
    atomic_store_explicit(&p->state, LIXH_STATE_OPEN, memory_order_release);
    emit(p, LIXH_EVT_STATE, atomic_load_explicit(&p->state, memory_order_acquire), "opened");
    return 0;
}

static int64_t frame_pts_ms(const AVFrame *f, AVRational tb) {
    if (!f || f->pts == AV_NOPTS_VALUE) return AV_NOPTS_VALUE;
    return av_rescale_q(f->pts, tb, (AVRational){1,1000});
}

enum { CHASE_NONE = 0, CHASE_SOFT = 1, CHASE_HARD = 2 };

static void video_anchor_set(LixhPlayer *p, int64_t pts) {
    atomic_store_explicit(&p->video_anchor_pts_ms, pts, memory_order_release);
    atomic_store_explicit(&p->video_anchor_wall_ms, now_ms(), memory_order_release);
}

/* wall−PTS drift since video anchor — used for present pacing (sleep2-like). */
static int64_t video_pace_lag_ms(LixhPlayer *p, int64_t pts) {
    int64_t anchor = atomic_load_explicit(&p->video_anchor_pts_ms, memory_order_acquire);
    if (anchor == AV_NOPTS_VALUE || pts == AV_NOPTS_VALUE) return 0;
    int64_t wall_elapsed = now_ms() - atomic_load_explicit(&p->video_anchor_wall_ms, memory_order_acquire);
    int64_t media_elapsed = pts - anchor;
    return wall_elapsed - media_elapsed;
}

static int64_t audio_drift_ms(LixhPlayer *p, int64_t pts) {
    int64_t anchor = atomic_load_explicit(&p->audio_anchor_pts_ms, memory_order_acquire);
    if (anchor == AV_NOPTS_VALUE || pts == AV_NOPTS_VALUE) return 0;
    int64_t wall_elapsed = now_ms() - atomic_load_explicit(&p->audio_anchor_wall_ms, memory_order_acquire);
    int64_t media_elapsed = pts - anchor;
    return wall_elapsed - media_elapsed;
}

/* Demux tip − frame PTS, minus the packet queue's own depth.
 *
 * tip - pts alone is not "how far behind we are": the demuxer deliberately runs
 * ahead and parks up to LIXH_VQ_MAX_MS of packets in the video queue. Feeding
 * that occupancy into the chase decision made soft chase impossible to exit
 * (exit needs backlog <= target, but the queue alone sat above it), so a
 * healthy stream lost a frame every second forever. Only the part that exceeds
 * what the queue is allowed to hold is real decode lateness. */
static int64_t video_backlog_ms(LixhPlayer *p, int64_t pts) {
    int64_t tip = atomic_load_explicit(&p->latest_video_pkt_pts_ms, memory_order_acquire);
    if (tip == AV_NOPTS_VALUE || pts == AV_NOPTS_VALUE) return 0;
    int64_t b = (tip - pts) - LIXH_VQ_MAX_MS;
    return b > 0 ? b : 0;
}

/* video_pts − heard_audio_pts: >0 video ahead of speakers (lips out of sync).
   Subtract PCM queue so we lock to what is actually playing, not decode tip. */
static int64_t av_skew_ms(LixhPlayer *p, int64_t vpts) {
    int64_t apts = atomic_load_explicit(&p->last_audio_pts_ms, memory_order_acquire);
    if (apts == AV_NOPTS_VALUE || vpts == AV_NOPTS_VALUE) return 0;
    int q = atomic_load_explicit(&p->audio_out_queue_ms, memory_order_acquire);
    if (q > 0 && q < 500) apts -= q;
    return vpts - apts;
}

/* Soft: keep skipping presents until backlog ≤ target.
   Hard: flush decoder then skip until frame is within target of tip.
   Never require decoded KEY flags (Douyin FLV / MediaCodec often omit them). */
static int live_chase_should_drop(LixhPlayer *p, int64_t pts, int is_key) {
    (void)is_key;
    int64_t now = now_ms();
    /* Surface / texture needs a first image. Dropping before any present leaves
       black screen with audio (listen→picture + short grace regression). */
    if (atomic_load_explicit(&p->video_frames, memory_order_relaxed) == 0) {
        video_anchor_set(p, pts);
        p->chase_mode = CHASE_NONE;
        atomic_store_explicit(&p->chase_need_flush, 0, memory_order_release);
        return 0;
    }
    /* Listen→picture join: show every frame so lag math is not poisoned. */
    if (p->video_join_grace_until_ms > 0 && now < p->video_join_grace_until_ms) {
        video_anchor_set(p, pts);
        p->chase_mode = CHASE_NONE;
        return 0;
    }

    if (atomic_load_explicit(&p->video_anchor_pts_ms, memory_order_acquire) == AV_NOPTS_VALUE) {
        video_anchor_set(p, pts);
        p->chase_mode = CHASE_NONE;
        return 0;
    }

    int64_t backlog = video_backlog_ms(p, pts);
    int64_t hard_th = p->max_latency_ms * 4;
    if (hard_th < 800) hard_th = 800;

    /* Audio-master: if video PTS is far behind heard audio, drop until near. */
    if (atomic_load_explicit(&p->video_sink, memory_order_acquire)) {
        int64_t skew = av_skew_ms(p, pts);
        if (skew < -180) {
            atomic_fetch_add_explicit(&p->dropped_frames, 1, memory_order_relaxed);
            return 1;
        }
    }

    if (p->chase_mode == CHASE_HARD) {
        int64_t tip = atomic_load_explicit(&p->latest_video_pkt_pts_ms, memory_order_acquire);
        /* Allow up to max_latency behind tip — target alone races a live tip
           after flush and can drop forever (sound, no picture). */
        int64_t slack = p->max_latency_ms > 0 ? p->max_latency_ms : p->target_latency_ms;
        if (slack < 200) slack = 200;
        int64_t want = (tip != AV_NOPTS_VALUE) ? (tip - slack) : pts;
        int64_t apts = atomic_load_explicit(&p->last_audio_pts_ms, memory_order_acquire);
        /* Exit early once lips are near audio even if still behind tip. */
        int near_audio = (apts != AV_NOPTS_VALUE && pts >= apts - 80);
        if (pts >= want || tip == AV_NOPTS_VALUE || near_audio) {
            video_anchor_set(p, pts);
            p->chase_mode = CHASE_NONE;
            return 0;
        }
        atomic_fetch_add_explicit(&p->dropped_frames, 1, memory_order_relaxed);
        return 1;
    }

    if (backlog > hard_th) {
        p->chase_mode = CHASE_HARD;
        atomic_store_explicit(&p->chase_need_flush, 1, memory_order_release);
        atomic_fetch_add_explicit(&p->dropped_frames, 1, memory_order_relaxed);
        return 1;
    }

    if (p->chase_mode == CHASE_SOFT) {
        if (backlog <= p->target_latency_ms) {
            video_anchor_set(p, pts);
            p->chase_mode = CHASE_NONE;
            return 0;
        }
        atomic_fetch_add_explicit(&p->dropped_frames, 1, memory_order_relaxed);
        return 1;
    }

    /* Hysteresis: enter soft only above max, exit below target. */
    if (p->max_latency_ms > 0 && backlog > p->max_latency_ms) {
        p->chase_mode = CHASE_SOFT;
        atomic_fetch_add_explicit(&p->dropped_frames, 1, memory_order_relaxed);
        return 1;
    }
    return 0;
}

static void deliver_video(LixhPlayer *p, AVFrame *f, AVRational tb) {
    int64_t pts = frame_pts_ms(f, tb);
    if (pts == AV_NOPTS_VALUE) {
#if defined(LIXH_ANDROID)
        release_mc_buffer(f, 0);
#endif
        return;
    }
    int64_t last_pts = atomic_load_explicit(&p->last_video_pts_ms, memory_order_acquire);
    if (last_pts != AV_NOPTS_VALUE && pts < last_pts - 1000) {
#if defined(LIXH_ANDROID)
        release_mc_buffer(f, 0);
#endif
        return;
    }
    int is_key = 0;
#if LIBAVUTIL_VERSION_MAJOR >= 58
    is_key = (f->flags & AV_FRAME_FLAG_KEY) != 0;
#else
    is_key = f->key_frame;
#endif
    if (live_chase_should_drop(p, pts, is_key)) {
#if defined(LIXH_ANDROID)
        /* MediaCodec buffers must be returned or the decoder stalls. */
        release_mc_buffer(f, 0);
#endif
        return;
    }
    /* A/V sync: audio is master. Hold video if ahead of heard audio; drop if
       far behind (handled above via chase). Wall pacing only as a fine polish. */
    if (p->chase_mode == CHASE_NONE &&
        atomic_load_explicit(&p->video_sink, memory_order_acquire)) {
        int64_t skew = av_skew_ms(p, pts);
        /* Software decode + RGBA present already trails the audio clock by
           1-2 frames; a tight -150ms floor dropped a frame every second or so
           on a healthy 8s/30s stream. Only give up on a frame when the gap is
           beyond what a normal pipeline can absorb. */
        int64_t behind_limit = p->max_latency_ms > 0 ? -(p->max_latency_ms + 400) : -600;
        if (skew > 60) {
            int64_t hold = skew - 40;
            if (hold > 35) hold = 35;
            if (hold > 0) av_usleep((unsigned)(hold * 1000));
        } else if (skew < behind_limit) {
            /* Still behind after chase soft path — skip present. */
#if defined(LIXH_ANDROID)
            release_mc_buffer(f, 0);
#endif
            atomic_fetch_add_explicit(&p->dropped_frames, 1, memory_order_relaxed);
            return;
        } else {
            int64_t pace = video_pace_lag_ms(p, pts);
            if (pace < -2) {
                int64_t ahead = -pace;
                if (ahead > 25) ahead = 25;
                av_usleep((unsigned)(ahead * 1000));
            }
        }
    } else if (p->chase_mode == CHASE_NONE) {
        int64_t pace = video_pace_lag_ms(p, pts);
        if (pace < -2) {
            int64_t ahead = -pace;
            if (ahead > 40) ahead = 40;
            av_usleep((unsigned)(ahead * 1000));
        }
    }
    atomic_store_explicit(&p->last_video_pts_ms, pts, memory_order_release);
    atomic_fetch_add_explicit(&p->video_frames, 1, memory_order_relaxed);
    if (f->width > 0 && f->height > 0) {
        atomic_store_explicit(&p->video_width, f->width, memory_order_relaxed);
        atomic_store_explicit(&p->video_height, f->height, memory_order_relaxed);
    }
    if (!p->cb.on_video) {
#if defined(LIXH_ANDROID)
        release_mc_buffer(f, 0);
#endif
        return;
    }
    if (f->format == AV_PIX_FMT_D3D11) {
#ifdef LIXH_WINDOWS
        /* on_video: 0=presented, 1=skip (keep trying direct), <0=force SW download.
           Never permanently demote after a single glitch — weak GPUs used to hit
           av_hwframe_transfer_data every frame and stall demux (play failed). */
        int direct = atomic_load_explicit(&p->direct_d3d11, memory_order_acquire);
        int presented = 1;
        if (direct >= 0) {
            ID3D11DeviceContext *frame_context = NULL;
            if (f->hw_frames_ctx) {
                AVHWFramesContext *frames = (AVHWFramesContext *)f->hw_frames_ctx->data;
                if (frames && frames->device_ctx) {
                    AVD3D11VADeviceContext *device = (AVD3D11VADeviceContext *)frames->device_ctx->hwctx;
                    if (device) frame_context = device->device_context;
                }
            }
            LixhNativeFrame nf = { LIXH_VIDEO_D3D11, f->width, f->height, f->data[0], (intptr_t)f->data[1], frame_context };
            presented = p->cb.on_video(p->cb.opaque, nf.kind, nf.width, nf.height, pts, 0, &nf);
            if (presented == 0) {
                atomic_store_explicit(&p->direct_d3d11, 1, memory_order_release);
                p->d3d11_fail_streak = 0;
            } else if (presented < 0) {
                /* Require a streak before committing to demux-thread SW path. */
                if (++p->d3d11_fail_streak >= 24) {
                    atomic_store_explicit(&p->direct_d3d11, -1, memory_order_release);
                } else {
                    atomic_fetch_add_explicit(&p->dropped_frames, 1, memory_order_relaxed);
                    return;
                }
            } else {
                /* skip: drop this frame, keep direct path */
                p->d3d11_fail_streak = 0;
                atomic_fetch_add_explicit(&p->dropped_frames, 1, memory_order_relaxed);
                return;
            }
        } else {
            presented = -1;
        }
        if (presented < 0 || direct < 0) {
            if (!p->transfer_frame) p->transfer_frame = av_frame_alloc();
            AVFrame *sw = p->transfer_frame;
            if (!sw) {
                atomic_fetch_add_explicit(&p->dropped_frames, 1, memory_order_relaxed);
                return;
            }
            av_frame_unref(sw);
            int rc = av_hwframe_transfer_data(sw, f, 0);
            if (rc >= 0) rc = av_frame_copy_props(sw, f);
            if (rc >= 0) {
                LixhNativeFrame fallback = { LIXH_VIDEO_SOFTWARE, sw->width, sw->height, sw, 0, sw };
                int sw_rc = p->cb.on_video(p->cb.opaque, fallback.kind, fallback.width, fallback.height, pts, 0, &fallback);
                if (sw_rc != 0) {
                    atomic_fetch_add_explicit(&p->dropped_frames, 1, memory_order_relaxed);
                }
            } else {
                atomic_fetch_add_explicit(&p->dropped_frames, 1, memory_order_relaxed);
                /* Do not emit ERROR — it overwrites UI and looks like play death. */
            }
            av_frame_unref(sw);
        }
#endif
    } else if (f->format == AV_PIX_FMT_VIDEOTOOLBOX) {
#if defined(LIXH_MACOS) || defined(LIXH_IOS)
        LixhNativeFrame nf = { LIXH_VIDEO_VIDEOTOOLBOX, f->width, f->height, f->data[3], 0, f };
        p->cb.on_video(p->cb.opaque, nf.kind, nf.width, nf.height, pts, 0, &nf);
#endif
#if defined(LIXH_ANDROID)
    } else if (f->format == AV_PIX_FMT_MEDIACODEC) {
        if (p->mc_surface_inited && f->data[3]) {
            /* Zero-copy: platform may skip (return !=0) → release without render. */
            LixhNativeFrame nf = { LIXH_VIDEO_MEDIACODEC, f->width, f->height, f->data[3], 0, f };
            int presented = p->cb.on_video(p->cb.opaque, nf.kind, nf.width, nf.height, pts, 0, &nf);
            int render = (presented == 0) ? 1 : 0;
            if (av_mediacodec_release_buffer((AVMediaCodecBuffer *)f->data[3], render) < 0) {
                atomic_fetch_add_explicit(&p->dropped_frames, 1, memory_order_relaxed);
            } else if (render) {
                atomic_store_explicit(&p->present_mode, LIXH_PRESENT_SURFACE, memory_order_relaxed);
            } else {
                atomic_fetch_add_explicit(&p->dropped_frames, 1, memory_order_relaxed);
            }
        } else {
            /* No Surface bind: GPU→CPU transfer then RGBA present. */
            if (!p->transfer_frame) p->transfer_frame = av_frame_alloc();
            AVFrame *sw = p->transfer_frame;
            if (!sw) {
                release_mc_buffer(f, 0);
                atomic_fetch_add_explicit(&p->dropped_frames, 1, memory_order_relaxed);
                return;
            }
            av_frame_unref(sw);
            int rc = av_hwframe_transfer_data(sw, f, 0);
            if (rc >= 0) rc = av_frame_copy_props(sw, f);
            /* Consumed HW buffer regardless of transfer outcome. */
            release_mc_buffer(f, 0);
            if (rc >= 0) {
                LixhNativeFrame fallback = { LIXH_VIDEO_SOFTWARE, sw->width, sw->height, sw, 0, sw };
                int sw_rc = p->cb.on_video(p->cb.opaque, fallback.kind, fallback.width, fallback.height, pts, 0, &fallback);
                if (sw_rc != 0) {
                    atomic_fetch_add_explicit(&p->dropped_frames, 1, memory_order_relaxed);
                } else {
                    atomic_store_explicit(&p->present_mode, LIXH_PRESENT_RGBA, memory_order_relaxed);
                }
            } else {
                atomic_fetch_add_explicit(&p->dropped_frames, 1, memory_order_relaxed);
            }
            av_frame_unref(sw);
        }
#endif
    } else {
        LixhNativeFrame nf = { LIXH_VIDEO_SOFTWARE, f->width, f->height, f, 0, f };
        int sw_rc = p->cb.on_video(p->cb.opaque, nf.kind, nf.width, nf.height, pts, 0, &nf);
        if (sw_rc == 0) {
            atomic_store_explicit(&p->present_mode, LIXH_PRESENT_RGBA, memory_order_relaxed);
        }
    }
}

static int ensure_audio_out(LixhPlayer *p, size_t needed) {
    if (needed <= p->audio_out_capacity) return 0;
    float *grown = (float *)av_realloc_array(p->audio_out, needed, sizeof(float));
    if (!grown) return -1;
    p->audio_out = grown;
    p->audio_out_capacity = needed;
    return 0;
}

static int ensure_audio_speed(LixhPlayer *p, size_t needed) {
    if (needed <= p->audio_speed_capacity) return 0;
    float *grown = (float *)av_realloc_array(p->audio_speed, needed, sizeof(float));
    if (!grown) return -1;
    p->audio_speed = grown;
    p->audio_speed_capacity = needed;
    return 0;
}

/* Catch-up is PCM drop-oldest only. Linear time-compress raises pitch and
   turns BGM/noise into a fast "吱吱" squeal — do not use it for listen. */
static int effective_rate_milli(LixhPlayer *p, int64_t pts) {
    (void)pts;
    p->rate_milli_applied = 1000;
    return 1000;
}

/* Linear time-compress. rate>1 → fewer samples, higher pitch. */
static int apply_play_rate(LixhPlayer *p, const float *in, int n_in, int ch,
                           int64_t pts, const float **out) {
    int milli = effective_rate_milli(p, pts);
    if (milli <= 1010 || n_in < 2 || ch <= 0) {
        *out = in;
        return n_in;
    }
    float rate = milli / 1000.f;
    int n_out = (int)(n_in / rate);
    if (n_out < 1) n_out = 1;
    size_t need = (size_t)n_out * (size_t)ch;
    if (ensure_audio_speed(p, need) < 0) {
        *out = in;
        return n_in;
    }
    for (int i = 0; i < n_out; ++i) {
        float pos = i * rate;
        int i0 = (int)pos;
        if (i0 >= n_in - 1) i0 = n_in - 2;
        int i1 = i0 + 1;
        float frac = pos - (float)i0;
        for (int c = 0; c < ch; ++c) {
            float s0 = in[i0 * ch + c];
            float s1 = in[i1 * ch + c];
            p->audio_speed[i * ch + c] = s0 + (s1 - s0) * frac;
        }
    }
    *out = p->audio_speed;
    return n_out;
}

static void emit_audio(LixhPlayer *p, int ch, int64_t pts, const float *samples, int n) {
    if (!samples || n <= 0) return;
    const float *out = NULL;
    int n_out = apply_play_rate(p, samples, n, ch, pts, &out);
    p->cb.on_audio(p->cb.opaque, p->sample_rate, ch, AV_SAMPLE_FMT_FLT, pts, out, n_out);
}

static void deliver_audio(LixhPlayer *p, AVFrame *f, AVRational tb) {
    int64_t pts = frame_pts_ms(f, tb);
    if (pts == AV_NOPTS_VALUE || !p->cb.on_audio) return;
    /* Never soft-chase audio; never touch video chase anchors. Live edge is
       trimmed in the platform PCM queue (+ optional play_rate). */
    if (atomic_load_explicit(&p->audio_anchor_pts_ms, memory_order_acquire) == AV_NOPTS_VALUE) {
        atomic_store_explicit(&p->audio_anchor_pts_ms, pts, memory_order_release);
        atomic_store_explicit(&p->audio_anchor_wall_ms, now_ms(), memory_order_release);
    }
    atomic_store_explicit(&p->last_audio_pts_ms, pts, memory_order_release);
    atomic_fetch_add_explicit(&p->audio_frames, 1, memory_order_relaxed);

    const int ch = p->channels > 0 ? p->channels : f->ch_layout.nb_channels;
    const int n_in = f->nb_samples;
    if (ch <= 0 || n_in <= 0) return;

    /* Fast path: AAC usually lands as FLTP — interleave without swr delay. */
    if (f->format == AV_SAMPLE_FMT_FLTP && f->extended_data) {
        size_t needed = (size_t)n_in * (size_t)ch;
        if (ensure_audio_out(p, needed) < 0) return;
        for (int i = 0; i < n_in; ++i) {
            for (int c = 0; c < ch; ++c) {
                const float *plane = (const float *)f->extended_data[c];
                p->audio_out[i * ch + c] = plane ? plane[i] : 0.f;
            }
        }
        emit_audio(p, ch, pts, p->audio_out, n_in);
        return;
    }
    if (f->format == AV_SAMPLE_FMT_FLT && f->data[0]) {
        emit_audio(p, ch, pts, (const float *)f->data[0], n_in);
        return;
    }

    if (!p->swr) return;
    int out_samples = av_rescale_rnd(swr_get_delay(p->swr, p->sample_rate) + n_in,
                                     p->sample_rate, p->sample_rate, AV_ROUND_UP);
    size_t needed = (size_t)out_samples * (size_t)ch;
    if (ensure_audio_out(p, needed) < 0) return;
    uint8_t *dst[1] = { (uint8_t *)p->audio_out };
    int n = swr_convert(p->swr, dst, out_samples, (const uint8_t **)f->extended_data, n_in);
    if (n > 0) emit_audio(p, ch, pts, p->audio_out, n);
}

static int decode_av_packet(LixhPlayer *p, AVCodecContext *dec, AVPacket *pkt, AVFrame *f,
                             int is_video, AVRational tb) {
    if (!dec || !pkt || !f) return 0;
    int rc = avcodec_send_packet(dec, pkt);
    if (rc < 0 && rc != AVERROR(EAGAIN)) return rc;
    while (!atomic_load_explicit(&p->stop, memory_order_acquire)) {
        av_frame_unref(f);
        rc = avcodec_receive_frame(dec, f);
        if (rc == AVERROR(EAGAIN) || rc == AVERROR_EOF) break;
        if (rc < 0) break;
        if (is_video) deliver_video(p, f, tb);
        else deliver_audio(p, f, tb);
    }
    av_frame_unref(f);
    return 0;
}


static void video_try_open_decoder(LixhPlayer *p) {
    if (!atomic_exchange_explicit(&p->open_video_req, 0, memory_order_acq_rel)) return;
    lixh_mutex_lock(&p->vdec_mu);
    if (!p->vdec && p->vstream >= 0 && p->fmt) {
        p->fmt->streams[p->vstream]->discard = AVDISCARD_DEFAULT;
        setup_hw(p);
        if (open_decoder(p, p->fmt->streams[p->vstream], 1) < 0) {
            emit(p, LIXH_EVT_INFO, -1, "video decoder deferred-open failed");
        } else {
            emit(p, LIXH_EVT_INFO, p->hw_kind, "video decoder opened");
            p->video_join_grace_until_ms = now_ms() + 1500;
        }
    }
    atomic_store_explicit(&p->direct_d3d11, 0, memory_order_release);
    p->d3d11_fail_streak = 0;
    lixh_mutex_unlock(&p->vdec_mu);
}

static void video_try_flush_decoder(LixhPlayer *p) {
    if (!atomic_exchange_explicit(&p->flush_video_req, 0, memory_order_acq_rel)) return;
    lixh_mutex_lock(&p->vdec_mu);
    if (p->vdec) avcodec_flush_buffers(p->vdec);
    atomic_store_explicit(&p->direct_d3d11, 0, memory_order_release);
    p->d3d11_fail_streak = 0;
    lixh_mutex_unlock(&p->vdec_mu);
}

static void video_try_chase_flush(LixhPlayer *p) {
    if (!atomic_exchange_explicit(&p->chase_need_flush, 0, memory_order_acq_rel)) return;
    lixh_mutex_lock(&p->vdec_mu);
    if (p->vdec) avcodec_flush_buffers(p->vdec);
    lixh_mutex_unlock(&p->vdec_mu);
}

static void *audio_worker(void *opaque) {
    LixhPlayer *p = (LixhPlayer *)opaque;
    AVPacket *pkt = av_packet_alloc();
    if (!pkt) return NULL;
    if (!p->audio_frame) p->audio_frame = av_frame_alloc();
    while (!atomic_load_explicit(&p->stop, memory_order_acquire)) {
        int got = pktq_pop(&p->aq, pkt, &p->stop);
        if (got <= 0) break;
        if (!p->adec || p->astream < 0 || !p->fmt) {
            av_packet_unref(pkt);
            continue;
        }
        AVRational tb = p->fmt->streams[p->astream]->time_base;
        decode_av_packet(p, p->adec, pkt, p->audio_frame, 0, tb);
        av_packet_unref(pkt);
    }
    av_packet_free(&pkt);
    return NULL;
}

static void *video_worker(void *opaque) {
    LixhPlayer *p = (LixhPlayer *)opaque;
    AVPacket *pkt = av_packet_alloc();
    if (!pkt) return NULL;
    if (!p->video_frame) p->video_frame = av_frame_alloc();
    while (!atomic_load_explicit(&p->stop, memory_order_acquire)) {
        video_try_open_decoder(p);
        video_try_flush_decoder(p);
        video_try_chase_flush(p);

        int got = pktq_pop(&p->vq, pkt, &p->stop);
        if (got <= 0) break;
        /* Pop may have blocked across sink enable — open before decode. */
        video_try_open_decoder(p);
        video_try_flush_decoder(p);
        if (!atomic_load_explicit(&p->video_sink, memory_order_acquire)) {
            av_packet_unref(pkt);
            continue;
        }
        /* Hold vdec_mu only around codec I/O — present/pacing runs unlocked
           so flush/open can proceed between frames. */
        lixh_mutex_lock(&p->vdec_mu);
        AVCodecContext *vdec = p->vdec;
        AVRational tb = (p->fmt && p->vstream >= 0)
                            ? p->fmt->streams[p->vstream]->time_base
                            : (AVRational){1, 1000};
        if (!vdec) {
            lixh_mutex_unlock(&p->vdec_mu);
            av_packet_unref(pkt);
            continue;
        }
        int send_rc = avcodec_send_packet(vdec, pkt);
        if (send_rc < 0 && send_rc != AVERROR(EAGAIN)) {
            lixh_mutex_unlock(&p->vdec_mu);
            av_packet_unref(pkt);
            continue;
        }
        if (!p->video_frame) p->video_frame = av_frame_alloc();
        AVFrame *f = p->video_frame;
        while (f && !atomic_load_explicit(&p->stop, memory_order_acquire)) {
            av_frame_unref(f);
            int rcf = avcodec_receive_frame(vdec, f);
            if (rcf == AVERROR(EAGAIN) || rcf == AVERROR_EOF) break;
            if (rcf < 0) break;
            lixh_mutex_unlock(&p->vdec_mu);
            deliver_video(p, f, tb);
            lixh_mutex_lock(&p->vdec_mu);
            vdec = p->vdec;
            if (!vdec) break;
        }
        if (f) av_frame_unref(f);
        lixh_mutex_unlock(&p->vdec_mu);
        av_packet_unref(pkt);
    }
    av_packet_free(&pkt);
    return NULL;
}


static int start_workers(LixhPlayer *p) {
    if (p->workers_up) return 0;
    if (!p->aq.inited && pktq_init(&p->aq, 0) < 0) return -1;
    if (!p->vq.inited && pktq_init(&p->vq, 1) < 0) return -1;
    pktq_reopen(&p->aq);
    pktq_reopen(&p->vq);
    if (!p->vdec_mu_inited) {
        lixh_mutex_init(&p->vdec_mu);
        p->vdec_mu_inited = 1;
    }
    if (lixh_thread_create(&p->audio_th, audio_worker, p) < 0) return -1;
    if (lixh_thread_create(&p->video_th, video_worker, p) < 0) {
        pktq_close(&p->aq);
        pktq_close(&p->vq);
        lixh_thread_join(p->audio_th);
        memset(&p->audio_th, 0, sizeof(p->audio_th));
        return -1;
    }
    p->workers_up = 1;
    return 0;
}

static void stop_workers(LixhPlayer *p) {
    if (!p->workers_up) {
        if (p->aq.inited) pktq_close(&p->aq);
        if (p->vq.inited) pktq_close(&p->vq);
        return;
    }
    pktq_close(&p->aq);
    pktq_close(&p->vq);
    lixh_thread_join(p->audio_th);
    lixh_thread_join(p->video_th);
    memset(&p->audio_th, 0, sizeof(p->audio_th));
    memset(&p->video_th, 0, sizeof(p->video_th));
    p->workers_up = 0;
}

void *lixh_player_create(const LixhCallbacks *cb) {
    LixhPlayer *p = (LixhPlayer *)calloc(1, sizeof(*p));
    if (!p) return NULL;
    if (cb) p->cb = *cb;
    p->vstream = p->astream = -1;
    atomic_init(&p->state, LIXH_STATE_IDLE);
    atomic_init(&p->stop, 0);
    atomic_init(&p->playing, 0);
    atomic_init(&p->direct_d3d11, 0);
    /* Default listen-first; UI enables picture after open when desired. */
    atomic_init(&p->video_sink, 0);
    atomic_init(&p->flush_video_req, 0);
    atomic_init(&p->open_video_req, 0);
    atomic_init(&p->present_mode, LIXH_PRESENT_NONE);
    atomic_init(&p->video_frames, 0);
    atomic_init(&p->audio_frames, 0);
    atomic_init(&p->dropped_frames, 0);
    atomic_init(&p->reconnects, 0);
    atomic_init(&p->bytes_read, 0);
    atomic_init(&p->video_width, 0);
    atomic_init(&p->video_height, 0);
    atomic_init(&p->video_anchor_pts_ms, AV_NOPTS_VALUE);
    atomic_init(&p->video_anchor_wall_ms, 0);
    atomic_init(&p->audio_anchor_pts_ms, AV_NOPTS_VALUE);
    atomic_init(&p->audio_anchor_wall_ms, 0);
    atomic_init(&p->last_video_pts_ms, AV_NOPTS_VALUE);
    atomic_init(&p->last_audio_pts_ms, AV_NOPTS_VALUE);
    atomic_init(&p->latest_video_pkt_pts_ms, AV_NOPTS_VALUE);
    /* Listen-first default: mild catch-up (秒听 uses ~1.3x). */
    atomic_init(&p->play_rate_milli, 1300);
    atomic_init(&p->audio_out_queue_ms, -1);
    atomic_init(&p->chase_need_flush, 0);
    p->rate_milli_applied = 1000;
    p->target_latency_ms = 100;
    p->max_latency_ms = 320;
    p->chase_mode = CHASE_NONE;
    p->video_join_grace_until_ms = 0;
    return p;
}

void lixh_player_destroy(void *opaque) {
    LixhPlayer *p = (LixhPlayer *)opaque;
    if (!p) return;
    lixh_player_stop(p);
    /* Ensure workers gone before freeing codec contexts. */
    atomic_store_explicit(&p->stop, 1, memory_order_release);
    stop_workers(p);
    if (p->aq.inited) pktq_destroy(&p->aq);
    if (p->vq.inited) pktq_destroy(&p->vq);
    if (p->vdec_mu_inited) { lixh_mutex_destroy(&p->vdec_mu); p->vdec_mu_inited = 0; }
    free_player_media(p);
    free(p->url);
    free(p->http_headers);
    free(p);
}

int lixh_player_open(void *opaque, const char *url) {
    LixhPlayer *p = (LixhPlayer *)opaque;
    if (!p || !url) return AVERROR(EINVAL);
    lixh_player_stop(p);
    atomic_store_explicit(&p->stop, 1, memory_order_release);
    stop_workers(p);
    free_player_media(p);
    free(p->url); p->url =
#ifdef LIXH_WINDOWS
        _strdup(url);
#else
        strdup(url);
#endif
    if (!p->url) return AVERROR(ENOMEM);
    atomic_store_explicit(&p->stop, 0, memory_order_release);
    atomic_store_explicit(&p->direct_d3d11, 0, memory_order_release);
    atomic_store_explicit(&p->video_anchor_pts_ms, AV_NOPTS_VALUE, memory_order_release);
    atomic_store_explicit(&p->audio_anchor_pts_ms, AV_NOPTS_VALUE, memory_order_release);
    atomic_store_explicit(&p->last_video_pts_ms, AV_NOPTS_VALUE, memory_order_release);
    atomic_store_explicit(&p->last_audio_pts_ms, AV_NOPTS_VALUE, memory_order_release);
    atomic_store_explicit(&p->latest_video_pkt_pts_ms, AV_NOPTS_VALUE, memory_order_release);
    p->chase_mode = CHASE_NONE;
    atomic_store_explicit(&p->chase_need_flush, 0, memory_order_release);
    int rc = open_input(p);
    if (rc < 0) { atomic_store_explicit(&p->state, LIXH_STATE_ERROR, memory_order_release); emit(p, LIXH_EVT_ERROR, rc, av_err2str(rc)); free_player_media(p); return rc; }
    return 0;
}

int lixh_player_play(void *opaque) {
    LixhPlayer *p = (LixhPlayer *)opaque;
    if (!p || !p->opened) return AVERROR(EINVAL);
    if (atomic_exchange_explicit(&p->playing, 1, memory_order_acq_rel)) return AVERROR(EALREADY);
    atomic_store_explicit(&p->stop, 0, memory_order_release);
    atomic_store_explicit(&p->state, LIXH_STATE_PLAYING, memory_order_release);
    emit(p, LIXH_EVT_STATE, atomic_load_explicit(&p->state, memory_order_acquire), "playing");
    if (start_workers(p) < 0) {
        atomic_store_explicit(&p->playing, 0, memory_order_release);
        atomic_store_explicit(&p->state, LIXH_STATE_ERROR, memory_order_release);
        emit(p, LIXH_EVT_ERROR, AVERROR(ENOMEM), "worker start failed");
        return AVERROR(ENOMEM);
    }
    AVPacket *pkt = av_packet_alloc();
    if (!pkt) {
        atomic_store_explicit(&p->stop, 1, memory_order_release);
        stop_workers(p);
        atomic_store_explicit(&p->playing, 0, memory_order_release);
        return AVERROR(ENOMEM);
    }
    int rc = 0;
    while (!atomic_load_explicit(&p->stop, memory_order_acquire)) {
        rc = av_read_frame(p->fmt, pkt);
        if (rc == AVERROR_EOF) break;
        if (rc < 0) {
            emit(p, LIXH_EVT_ERROR, rc, av_err2str(rc));
            /* Reconnect: join workers first (queue close wakes them). Do not
               raise stop — that is reserved for user/UI cancel. */
            stop_workers(p);
            int recovered = 0;
            for (int attempt = 1; attempt <= 3; ++attempt) {
                if (atomic_load_explicit(&p->stop, memory_order_acquire)) break;
                atomic_fetch_add_explicit(&p->reconnects, 1, memory_order_relaxed);
                emit(p, LIXH_EVT_INFO, attempt, "reconnecting");
                av_usleep((unsigned)(attempt * 250000));
                if (atomic_load_explicit(&p->stop, memory_order_acquire)) break;
                free_player_media(p);
                if (open_input(p) == 0) { recovered = 1; break; }
            }
            if (recovered && !atomic_load_explicit(&p->stop, memory_order_acquire)) {
                atomic_store_explicit(&p->direct_d3d11, 0, memory_order_release);
                atomic_store_explicit(&p->video_anchor_pts_ms, AV_NOPTS_VALUE, memory_order_release);
                atomic_store_explicit(&p->audio_anchor_pts_ms, AV_NOPTS_VALUE, memory_order_release);
                atomic_store_explicit(&p->last_video_pts_ms, AV_NOPTS_VALUE, memory_order_release);
                atomic_store_explicit(&p->last_audio_pts_ms, AV_NOPTS_VALUE, memory_order_release);
                atomic_store_explicit(&p->latest_video_pkt_pts_ms, AV_NOPTS_VALUE, memory_order_release);
                p->chase_mode = CHASE_NONE;
                atomic_store_explicit(&p->chase_need_flush, 0, memory_order_release);
                p->d3d11_fail_streak = 0;
                if (start_workers(p) < 0) { rc = AVERROR(ENOMEM); break; }
                rc = 0; continue;
            }
            break;
        }
        /* Demux-only: keep discard in sync with listen↔picture. */
        if (p->vstream >= 0 && p->fmt && p->fmt->streams[p->vstream]) {
            int want_v = atomic_load_explicit(&p->video_sink, memory_order_acquire);
            enum AVDiscard want_d = want_v ? AVDISCARD_DEFAULT : AVDISCARD_ALL;
            if (p->fmt->streams[p->vstream]->discard != want_d) {
                p->fmt->streams[p->vstream]->discard = want_d;
            }
        }
        if (pkt->size > 0) {
            atomic_fetch_add_explicit(&p->bytes_read, (uint64_t)pkt->size, memory_order_relaxed);
        }
        if (pkt->stream_index == p->astream && p->astream >= 0) {
            AVRational atb = p->fmt->streams[p->astream]->time_base;
            int64_t pts = pkt_pts_ms(pkt, atb);
            if (pktq_push(&p->aq, pkt, pts, 0, &p->dropped_frames) < 0)
                av_packet_unref(pkt);
        } else if (pkt->stream_index == p->vstream && p->vstream >= 0) {
            int sink = atomic_load_explicit(&p->video_sink, memory_order_acquire);
            /* Enqueue even before vdec opens so tip advances; worker waits for vdec. */
            if (!sink) {
                av_packet_unref(pkt);
            } else {
                AVRational vtb = p->fmt->streams[p->vstream]->time_base;
                int64_t pts = pkt_pts_ms(pkt, vtb);
                if (pts != AV_NOPTS_VALUE) {
                    atomic_store_explicit(&p->latest_video_pkt_pts_ms, pts, memory_order_release);
                }
                int key = (pkt->flags & AV_PKT_FLAG_KEY) != 0;
                if (pktq_push(&p->vq, pkt, pts, key, &p->dropped_frames) < 0)
                    av_packet_unref(pkt);
            }
        } else {
            av_packet_unref(pkt);
        }
    }
    av_packet_free(&pkt);
    {
        int ended_by_stop = atomic_load_explicit(&p->stop, memory_order_acquire);
        int fail = (rc < 0 && rc != AVERROR_EOF);
        atomic_store_explicit(&p->stop, 1, memory_order_release);
        stop_workers(p);
        if (fail && !ended_by_stop)
            atomic_store_explicit(&p->state, LIXH_STATE_ERROR, memory_order_release);
        else
            atomic_store_explicit(&p->state, LIXH_STATE_STOPPED, memory_order_release);
        emit(p, LIXH_EVT_STATE, atomic_load_explicit(&p->state, memory_order_acquire),
             ended_by_stop ? "stopped" : (fail ? "error" : "eof"));
    }
    atomic_store_explicit(&p->playing, 0, memory_order_release);
    return rc < 0 && rc != AVERROR_EOF ? rc : 0;
}

void lixh_player_stop(void *opaque) {
    LixhPlayer *p = (LixhPlayer *)opaque;
    if (!p) return;
    atomic_store_explicit(&p->stop, 1, memory_order_release);
    if (p->aq.inited) pktq_close(&p->aq);
    if (p->vq.inited) pktq_close(&p->vq);
    if (atomic_load_explicit(&p->state, memory_order_acquire) == LIXH_STATE_PLAYING)
        atomic_store_explicit(&p->state, LIXH_STATE_STOPPED, memory_order_release);
}

void lixh_player_set_latency(void *opaque, int64_t target_ms, int64_t max_ms) {
    LixhPlayer *p = (LixhPlayer *)opaque;
    if (!p) return;
    if (target_ms > 0) p->target_latency_ms = target_ms;
    if (max_ms > 0) p->max_latency_ms = max_ms;
}

void lixh_player_set_headers(void *opaque, const char *headers) {
    LixhPlayer *p = (LixhPlayer *)opaque;
    if (!p) return;
    free(p->http_headers);
    p->http_headers = NULL;
    if (!headers || !headers[0]) return;
#ifdef LIXH_WINDOWS
    p->http_headers = _strdup(headers);
#else
    p->http_headers = strdup(headers);
#endif
}

void lixh_player_set_play_rate(void *opaque, float rate) {
    LixhPlayer *p = (LixhPlayer *)opaque;
    if (!p) return;
    if (rate < 1.f) rate = 1.f;
    if (rate > 1.5f) rate = 1.5f;
    int milli = (int)(rate * 1000.f + 0.5f);
    if (milli < 1000) milli = 1000;
    if (milli > 1500) milli = 1500;
    atomic_store_explicit(&p->play_rate_milli, milli, memory_order_release);
    /* Reset hysteresis so a user change takes effect immediately. */
    p->rate_milli_applied = milli <= 1010 ? 1000 : p->rate_milli_applied;
}

void lixh_player_report_audio_queue_ms(void *opaque, int queue_ms) {
    LixhPlayer *p = (LixhPlayer *)opaque;
    if (!p) return;
    if (queue_ms < 0) queue_ms = 0;
    if (queue_ms > 5000) queue_ms = 5000;
    atomic_store_explicit(&p->audio_out_queue_ms, queue_ms, memory_order_release);
}

void lixh_player_set_video_sink(void *opaque, int enabled) {
    LixhPlayer *p = (LixhPlayer *)opaque;
    if (!p) return;
    int on = enabled ? 1 : 0;
    int prev = atomic_exchange_explicit(&p->video_sink, on, memory_order_acq_rel);
    /* Picture: cap mild catch-up; listen restores full ceiling via set_play_rate. */
    if (on) {
        int cur = atomic_load_explicit(&p->play_rate_milli, memory_order_acquire);
        if (cur > 1150) {
            atomic_store_explicit(&p->play_rate_milli, 1150, memory_order_release);
        }
    }
    /* Never touch AVCodecContext from the UI thread — play loop opens/flushes. */
    if (on && !prev) {
        if (!p->vdec) {
            atomic_store_explicit(&p->open_video_req, 1, memory_order_release);
        } else {
            atomic_store_explicit(&p->flush_video_req, 1, memory_order_release);
        }
        /* Reset video chase only — audio anchors stay so listen→picture does
           not let the next PCM packet re-base video lag. */
        atomic_store_explicit(&p->video_anchor_pts_ms, AV_NOPTS_VALUE, memory_order_release);
        atomic_store_explicit(&p->last_video_pts_ms, AV_NOPTS_VALUE, memory_order_release);
        atomic_store_explicit(&p->latest_video_pkt_pts_ms, AV_NOPTS_VALUE, memory_order_release);
        atomic_store_explicit(&p->video_frames, 0, memory_order_relaxed);
        p->chase_mode = CHASE_NONE;
        atomic_store_explicit(&p->chase_need_flush, 0, memory_order_release);
        /* Long enough for deferred MediaCodec open + first present. */
        p->video_join_grace_until_ms = now_ms() + 2000;
        atomic_store_explicit(&p->direct_d3d11, 0, memory_order_release);
        p->d3d11_fail_streak = 0;
    }
}

void lixh_player_set_android_surface(void *opaque, void *surface) {
    LixhPlayer *p = (LixhPlayer *)opaque;
    if (!p) return;
#if defined(LIXH_ANDROID)
    p->android_surface = surface;
#else
    (void)surface;
#endif
}

int lixh_player_get_stats(void *opaque, LixhStats *out) {
    LixhPlayer *p = (LixhPlayer *)opaque;
    if (!p || !out) return AVERROR(EINVAL);
    memset(out, 0, sizeof(*out));
    out->state = atomic_load_explicit(&p->state, memory_order_acquire);
    out->video_frames = atomic_load_explicit(&p->video_frames, memory_order_relaxed);
    out->audio_frames = atomic_load_explicit(&p->audio_frames, memory_order_relaxed);
    out->dropped_frames = atomic_load_explicit(&p->dropped_frames, memory_order_relaxed);
    out->reconnects = atomic_load_explicit(&p->reconnects, memory_order_relaxed);
    out->last_video_pts_ms = atomic_load_explicit(&p->last_video_pts_ms, memory_order_acquire);
    out->last_audio_pts_ms = atomic_load_explicit(&p->last_audio_pts_ms, memory_order_acquire);
    out->bytes_read = atomic_load_explicit(&p->bytes_read, memory_order_relaxed);
    out->video_width = atomic_load_explicit(&p->video_width, memory_order_relaxed);
    out->video_height = atomic_load_explicit(&p->video_height, memory_order_relaxed);
    out->chase_mode = p->chase_mode;
    /* Picture: demux tip − last present. Listen: PCM queue, else audio drift. */
    int64_t lag = 0;
    int sink = atomic_load_explicit(&p->video_sink, memory_order_acquire);
    int64_t now = now_ms();
    int in_grace = (p->video_join_grace_until_ms > 0 && now < p->video_join_grace_until_ms);
    if (sink && out->last_video_pts_ms != AV_NOPTS_VALUE) {
        lag = video_backlog_ms(p, out->last_video_pts_ms);
    } else if (sink) {
        lag = 0;
    } else {
        int q = atomic_load_explicit(&p->audio_out_queue_ms, memory_order_acquire);
        if (q >= 0) lag = q;
        else if (out->last_audio_pts_ms != AV_NOPTS_VALUE)
            lag = audio_drift_ms(p, out->last_audio_pts_ms);
    }
    if (lag < 0) lag = 0;
    if (in_grace && lag > 500) lag = 500;
    /* Cap well below 60s so a stuck present cannot pin the UI at 60000. */
    if (lag > 5000) lag = 5000;
    out->input_buffer_ms = lag;
    out->decode_hw = p->hw_kind;
    out->present_mode = atomic_load_explicit(&p->present_mode, memory_order_relaxed);
    return 0;
}
