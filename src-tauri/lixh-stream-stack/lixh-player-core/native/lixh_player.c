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

typedef struct LixhPlayer {
    LixhCallbacks cb;
    AVFormatContext *fmt;
    AVCodecContext *vdec;
    AVCodecContext *adec;
    AVBufferRef *hw_device;
    SwrContext *swr;
    AVFrame *decode_frame;
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
    atomic_int_fast64_t latest_audio_pkt_pts_ms;
    /* >0: interrupt av_read_frame so listen tip-batch gather can stop. */
    int64_t gather_deadline_ms;
    atomic_uint_fast64_t video_frames;
    atomic_uint_fast64_t audio_frames;
    atomic_uint_fast64_t dropped_frames;
    atomic_uint_fast64_t reconnects;
    atomic_uint_fast64_t bytes_read;
    atomic_int video_width;
    atomic_int video_height;
    int64_t target_latency_ms;
    int64_t max_latency_ms;
    /* 0=none, 1=soft (decode but skip present), 2=hard (next frame re-anchors). */
    int chase_mode;
    int chase_drop_streak;
    /* After listen→picture: present every frame for a while (no chase drops). */
    int64_t video_join_grace_until_ms;
    /* Consecutive on_video <0 before committing to demux-thread SW download. */
    int d3d11_fail_streak;
    int sample_rate;
    int channels;
    /* Audio play rate ×1000 (1000=1.0x). Listen catch-up often ~1300. */
    atomic_int play_rate_milli;
    float *audio_speed;
    size_t audio_speed_capacity;
} LixhPlayer;

static void emit(LixhPlayer *p, int type, int code, const char *msg) {
    if (p && p->cb.on_event) p->cb.on_event(p->cb.opaque, type, code, msg ? msg : "");
}

static int64_t now_ms(void) { return av_gettime_relative() / 1000; }

static int interrupt_cb(void *opaque) {
    LixhPlayer *p = (LixhPlayer *)opaque;
    if (!p) return 0;
    if (atomic_load_explicit(&p->stop, memory_order_acquire)) return 1;
    /* Tip-batch gather: abort blocked read once the short window ends. */
    if (p->gather_deadline_ms > 0 && now_ms() >= p->gather_deadline_ms) return 1;
    return 0;
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
    if (p->decode_frame) av_frame_free(&p->decode_frame);
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
    int rc = av_hwdevice_ctx_create(&p->hw_device, AV_HWDEVICE_TYPE_MEDIACODEC, NULL, NULL, 0);
    if (rc < 0) {
        p->hw_device = NULL;
        p->hw_kind = LIXH_VIDEO_SOFTWARE;
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

static int open_decoder(LixhPlayer *p, AVStream *st, int video) {
    const AVCodec *codec = avcodec_find_decoder(st->codecpar->codec_id);
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
        if (p->hw_device && p->android_surface) {
            AVMediaCodecContext *mc = av_mediacodec_alloc_context();
            if (mc) {
                if (av_mediacodec_default_init(ctx, mc, p->android_surface) == 0) {
                    p->mc_surface_inited = 1;
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

static int open_input(LixhPlayer *p) {
    AVDictionary *opts = NULL;
    av_dict_set(&opts, "fflags", "nobuffer+discardcorrupt+flush_packets", 0);
    av_dict_set(&opts, "max_delay", "0", 0);
    av_dict_set(&opts, "flags", "low_delay", 0);
    /* Tight probe for faster join (listen-first cares about TTFB to audio).
       Even tighter when picture is off — we only need the audio stream. */
    if (!atomic_load_explicit(&p->video_sink, memory_order_acquire)) {
        av_dict_set(&opts, "probesize", "65536", 0);
        av_dict_set(&opts, "analyzeduration", "80000", 0);
    } else {
        av_dict_set(&opts, "probesize", "163840", 0);
        av_dict_set(&opts, "analyzeduration", "150000", 0);
    }
    av_dict_set(&opts, "rw_timeout", "2000000", 0);
    av_dict_set(&opts, "timeout", "2000000", 0);
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
    rc = avformat_find_stream_info(p->fmt, NULL);
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

/* wall−PTS drift since video anchor. Measures catch-up backlog / clock skew,
   not absolute delay to the live site. */
static int64_t video_chase_lag_ms(LixhPlayer *p, int64_t pts) {
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

/* Prefer demux tip behind (chase newest); fall back to wall−PTS drift. */
static int64_t video_live_lag_ms(LixhPlayer *p, int64_t pts) {
    int64_t tip = atomic_load_explicit(&p->latest_video_pkt_pts_ms, memory_order_acquire);
    int64_t tip_behind = 0;
    if (tip != AV_NOPTS_VALUE && pts != AV_NOPTS_VALUE && tip >= pts) {
        tip_behind = tip - pts;
    }
    int64_t wall = video_chase_lag_ms(p, pts);
    return tip_behind > wall ? tip_behind : wall;
}

/* Soft: skip a few presents then re-anchor. Hard: skip one present, next shows.
   Never require decoded KEY flags (MediaCodec often omits them). */
static int live_chase_should_drop(LixhPlayer *p, int64_t pts, int is_key) {
    (void)is_key;
    int64_t now = now_ms();
    /* Listen→picture join: show every frame so Surface gets a first image and
       lag math is not poisoned by decoder warm-up wall time. */
    if (p->video_join_grace_until_ms > 0 && now < p->video_join_grace_until_ms) {
        video_anchor_set(p, pts);
        p->chase_mode = CHASE_NONE;
        p->chase_drop_streak = 0;
        return 0;
    }

    if (atomic_load_explicit(&p->video_anchor_pts_ms, memory_order_acquire) == AV_NOPTS_VALUE) {
        video_anchor_set(p, pts);
        p->chase_mode = CHASE_NONE;
        p->chase_drop_streak = 0;
        return 0;
    }

    if (p->chase_mode == CHASE_HARD) {
        video_anchor_set(p, pts);
        p->chase_mode = CHASE_NONE;
        p->chase_drop_streak = 0;
        return 0;
    }

    int64_t live_lag = video_live_lag_ms(p, pts);
    if (live_lag > p->max_latency_ms) {
        /* Drop this present; next frame re-anchors (present-only hard). */
        p->chase_mode = CHASE_HARD;
        p->chase_drop_streak = 1;
        atomic_fetch_add_explicit(&p->dropped_frames, 1, memory_order_relaxed);
        return 1;
    }
    if (p->target_latency_ms > 0 && live_lag > p->target_latency_ms) {
        p->chase_mode = CHASE_SOFT;
        int over = (int)(live_lag - p->target_latency_ms);
        int span = (int)(p->max_latency_ms - p->target_latency_ms);
        if (span < 1) span = 1;
        int need_streak = 6 - (over * 3) / span;
        if (need_streak < 2) need_streak = 2;
        if (need_streak > 6) need_streak = 6;
        if (p->chase_drop_streak < need_streak) {
            p->chase_drop_streak++;
            atomic_fetch_add_explicit(&p->dropped_frames, 1, memory_order_relaxed);
            return 1;
        }
        video_anchor_set(p, pts);
        p->chase_mode = CHASE_NONE;
        p->chase_drop_streak = 0;
        return 0;
    }
    p->chase_mode = CHASE_NONE;
    p->chase_drop_streak = 0;
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

/* Mild rate only — heavy backlog is tip-skipped in the demux batch so voice
   stays near 1.0x (no long pitch-up). Ceiling still applies as a soft assist. */
static int effective_rate_milli(LixhPlayer *p, int64_t pts) {
    int max_milli = atomic_load_explicit(&p->play_rate_milli, memory_order_acquire);
    if (max_milli <= 1010) return 1000;
    /* Cap assist at 1.15x for clarity; tip-batch does the hard catch-up. */
    if (max_milli > 1150) max_milli = 1150;
    int64_t tip = atomic_load_explicit(&p->latest_audio_pkt_pts_ms, memory_order_acquire);
    int64_t tip_behind = 0;
    if (tip != AV_NOPTS_VALUE && pts != AV_NOPTS_VALUE && tip >= pts) {
        tip_behind = tip - pts;
    }
    int64_t drift = audio_drift_ms(p, pts);
    int64_t lag = tip_behind > drift ? tip_behind : drift;
    if (lag < 100) return 1000;
    if (lag < 220) {
        int span = max_milli - 1000;
        return 1000 + (int)(span * (lag - 100) / 120);
    }
    return max_milli;
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
    /* Tip chase is demux-batch (listen) + PCM trim; mild play_rate assist only.
       Never touch video chase anchors from audio. */
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

static int decode_packet(LixhPlayer *p, AVPacket *pkt) {
    AVCodecContext *dec = pkt->stream_index == p->vstream ? p->vdec : p->adec;
    if (!dec) return 0;
    int rc = avcodec_send_packet(dec, pkt);
    if (rc < 0 && rc != AVERROR(EAGAIN)) return rc;
    if (!p->decode_frame) p->decode_frame = av_frame_alloc();
    AVFrame *f = p->decode_frame;
    if (!f) return AVERROR(ENOMEM);
    AVRational tb = p->fmt->streams[pkt->stream_index]->time_base;
    while (!atomic_load_explicit(&p->stop, memory_order_acquire)) {
        av_frame_unref(f);
        rc = avcodec_receive_frame(dec, f);
        if (rc == AVERROR(EAGAIN) || rc == AVERROR_EOF) break;
        if (rc < 0) break;
        if (pkt->stream_index == p->vstream) deliver_video(p, f, tb);
        else deliver_audio(p, f, tb);
    }
    av_frame_unref(f);
    return 0;
}

enum { LIXH_TIP_BATCH = 48 };

static int64_t packet_pts_ms(const AVPacket *pkt, AVRational tb) {
    if (!pkt || pkt->pts == AV_NOPTS_VALUE) return AV_NOPTS_VALUE;
    return av_rescale_q(pkt->pts, tb, (AVRational){1, 1000});
}

/* Decode only packets near demux tip — drop older backlog in one jump.
   Keeps voice at ~1.0x after the skip instead of long pitch-up catch-up. */
static void decode_audio_tip_batch(LixhPlayer *p, AVPacket **batch, int n,
                                  int64_t tip_ms) {
    if (n <= 0) return;
    /* Keep only packets within target of tip (hard jump to live edge). */
    int64_t keep = p->target_latency_ms > 0 ? p->target_latency_ms : 80;
    if (keep < 40) keep = 40;
    int skipped = 0;
    for (int i = 0; i < n; ++i) {
        AVPacket *pkt = batch[i];
        if (!pkt) continue;
        AVRational tb = p->fmt->streams[p->astream]->time_base;
        int64_t pts = packet_pts_ms(pkt, tb);
        if (tip_ms != AV_NOPTS_VALUE && pts != AV_NOPTS_VALUE &&
            tip_ms - pts > keep) {
            if (!skipped && p->adec) avcodec_flush_buffers(p->adec);
            skipped = 1;
            atomic_fetch_add_explicit(&p->dropped_frames, 1, memory_order_relaxed);
            av_packet_free(&batch[i]);
            continue;
        }
        decode_packet(p, pkt);
        av_packet_free(&batch[i]);
    }
    if (skipped) {
        atomic_store_explicit(&p->audio_anchor_pts_ms, AV_NOPTS_VALUE,
                              memory_order_release);
    }
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
    atomic_init(&p->latest_audio_pkt_pts_ms, AV_NOPTS_VALUE);
    p->gather_deadline_ms = 0;
    /* Mild assist only; tip-batch does hard catch-up for clear speech. */
    atomic_init(&p->play_rate_milli, 1150);
    p->target_latency_ms = 100;
    p->max_latency_ms = 320;
    p->chase_mode = CHASE_NONE;
    p->chase_drop_streak = 0;
    p->video_join_grace_until_ms = 0;
    return p;
}

void lixh_player_destroy(void *opaque) {
    LixhPlayer *p = (LixhPlayer *)opaque;
    if (!p) return;
    lixh_player_stop(p);
    free_player_media(p);
    free(p->url);
    free(p->http_headers);
    free(p);
}

int lixh_player_open(void *opaque, const char *url) {
    LixhPlayer *p = (LixhPlayer *)opaque;
    if (!p || !url) return AVERROR(EINVAL);
    lixh_player_stop(p);
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
    p->chase_drop_streak = 0;
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
    AVPacket *pkt = av_packet_alloc();
    if (!pkt) { atomic_store_explicit(&p->playing, 0, memory_order_release); return AVERROR(ENOMEM); }
    int rc = 0;
    while (!atomic_load_explicit(&p->stop, memory_order_acquire)) {
        rc = av_read_frame(p->fmt, pkt);
        if (rc == AVERROR_EOF) break;
        if (rc < 0) {
            emit(p, LIXH_EVT_ERROR, rc, av_err2str(rc));
            int recovered = 0;
            for (int attempt = 1; attempt <= 3 && !atomic_load_explicit(&p->stop, memory_order_acquire); ++attempt) {
                atomic_fetch_add_explicit(&p->reconnects, 1, memory_order_relaxed);
                emit(p, LIXH_EVT_INFO, attempt, "reconnecting");
                av_usleep((unsigned)(attempt * 250000));
                free_player_media(p);
                if (open_input(p) == 0) { recovered = 1; break; }
            }
            if (recovered) {
                atomic_store_explicit(&p->direct_d3d11, 0, memory_order_release);
                atomic_store_explicit(&p->video_anchor_pts_ms, AV_NOPTS_VALUE, memory_order_release);
                atomic_store_explicit(&p->audio_anchor_pts_ms, AV_NOPTS_VALUE, memory_order_release);
                atomic_store_explicit(&p->last_video_pts_ms, AV_NOPTS_VALUE, memory_order_release);
                atomic_store_explicit(&p->last_audio_pts_ms, AV_NOPTS_VALUE, memory_order_release);
                atomic_store_explicit(&p->latest_video_pkt_pts_ms, AV_NOPTS_VALUE, memory_order_release);
                atomic_store_explicit(&p->latest_audio_pkt_pts_ms, AV_NOPTS_VALUE, memory_order_release);
                p->gather_deadline_ms = 0;
                p->chase_mode = CHASE_NONE;
                p->chase_drop_streak = 0;
                p->d3d11_fail_streak = 0;
                rc = 0; continue;
            }
            break;
        }
        if (atomic_exchange_explicit(&p->open_video_req, 0, memory_order_acq_rel)) {
            if (!p->vdec && p->vstream >= 0 && p->fmt) {
                p->fmt->streams[p->vstream]->discard = AVDISCARD_DEFAULT;
                setup_hw(p);
                if (open_decoder(p, p->fmt->streams[p->vstream], 1) < 0) {
                    emit(p, LIXH_EVT_INFO, -1, "video decoder deferred-open failed");
                } else {
                    emit(p, LIXH_EVT_INFO, p->hw_kind, "video decoder opened");
                    /* Extra grace once the decoder is actually up. */
                    p->video_join_grace_until_ms = now_ms() + 2500;
                }
            }
            atomic_store_explicit(&p->direct_d3d11, 0, memory_order_release);
            p->d3d11_fail_streak = 0;
        }
        if (atomic_exchange_explicit(&p->flush_video_req, 0, memory_order_acq_rel)) {
            if (p->vdec) avcodec_flush_buffers(p->vdec);
            atomic_store_explicit(&p->direct_d3d11, 0, memory_order_release);
            p->d3d11_fail_streak = 0;
        }
        /* Keep demux discard in sync with listen↔picture (play thread only). */
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
        if (pkt->stream_index == p->vstream &&
            (!atomic_load_explicit(&p->video_sink, memory_order_acquire) || !p->vdec)) {
            av_packet_unref(pkt);
            continue;
        }
        /* Listen-only: gather a short demux burst, decode only near tip. */
        if (pkt->stream_index == p->astream &&
            !atomic_load_explicit(&p->video_sink, memory_order_acquire) &&
            p->astream >= 0) {
            AVPacket *batch[LIXH_TIP_BATCH];
            memset(batch, 0, sizeof(batch));
            int bn = 0;
            int64_t tip = AV_NOPTS_VALUE;
            AVRational atb = p->fmt->streams[p->astream]->time_base;
            batch[bn] = av_packet_clone(pkt);
            if (!batch[bn]) {
                decode_packet(p, pkt);
                av_packet_unref(pkt);
                continue;
            }
            tip = packet_pts_ms(batch[bn], atb);
            if (tip != AV_NOPTS_VALUE) {
                atomic_store_explicit(&p->latest_audio_pkt_pts_ms, tip,
                                      memory_order_release);
            }
            bn++;
            av_packet_unref(pkt);
            p->gather_deadline_ms = now_ms() + 8;
            while (bn < LIXH_TIP_BATCH &&
                   !atomic_load_explicit(&p->stop, memory_order_acquire)) {
                AVPacket *more = av_packet_alloc();
                if (!more) break;
                int grc = av_read_frame(p->fmt, more);
                if (grc < 0) {
                    av_packet_free(&more);
                    break;
                }
                if (more->size > 0) {
                    atomic_fetch_add_explicit(&p->bytes_read, (uint64_t)more->size,
                                             memory_order_relaxed);
                }
                if (more->stream_index == p->vstream) {
                    av_packet_free(&more);
                    continue;
                }
                if (more->stream_index != p->astream) {
                    av_packet_free(&more);
                    continue;
                }
                int64_t pts = packet_pts_ms(more, atb);
                if (pts != AV_NOPTS_VALUE) {
                    tip = pts;
                    atomic_store_explicit(&p->latest_audio_pkt_pts_ms, tip,
                                          memory_order_release);
                }
                batch[bn++] = more;
                /* Enough backlog already — stop gathering and jump to tip. */
                if (tip != AV_NOPTS_VALUE && bn > 1) {
                    int64_t first = packet_pts_ms(batch[0], atb);
                    int64_t hard = p->max_latency_ms > 0 ? p->max_latency_ms : 160;
                    if (first != AV_NOPTS_VALUE && tip - first > hard * 2) break;
                }
            }
            p->gather_deadline_ms = 0;
            decode_audio_tip_batch(p, batch, bn, tip);
            rc = 0;
            continue;
        }
        if (pkt->stream_index == p->vstream) {
            AVRational vtb = p->fmt->streams[p->vstream]->time_base;
            if (pkt->pts != AV_NOPTS_VALUE) {
                int64_t pkt_pts = av_rescale_q(pkt->pts, vtb, (AVRational){1, 1000});
                atomic_store_explicit(&p->latest_video_pkt_pts_ms, pkt_pts, memory_order_release);
            }
        }
        if (pkt->stream_index == p->astream) {
            AVRational atb = p->fmt->streams[p->astream]->time_base;
            int64_t pts = packet_pts_ms(pkt, atb);
            if (pts != AV_NOPTS_VALUE) {
                atomic_store_explicit(&p->latest_audio_pkt_pts_ms, pts,
                                      memory_order_release);
            }
        }
        if (pkt->stream_index == p->vstream || pkt->stream_index == p->astream) {
            decode_packet(p, pkt);
        }
        av_packet_unref(pkt);
    }
    av_packet_free(&pkt);
    if (!atomic_load_explicit(&p->stop, memory_order_acquire) && rc < 0) atomic_store_explicit(&p->state, LIXH_STATE_ERROR, memory_order_release);
    else atomic_store_explicit(&p->state, LIXH_STATE_STOPPED, memory_order_release);
    emit(p, LIXH_EVT_STATE, atomic_load_explicit(&p->state, memory_order_acquire), atomic_load_explicit(&p->stop, memory_order_acquire) ? "stopped" : "eof");
    atomic_store_explicit(&p->playing, 0, memory_order_release);
    return rc < 0 && rc != AVERROR_EOF ? rc : 0;
}

void lixh_player_stop(void *opaque) {
    LixhPlayer *p = (LixhPlayer *)opaque;
    if (!p) return;
    atomic_store_explicit(&p->stop, 1, memory_order_release);
    if (atomic_load_explicit(&p->state, memory_order_acquire) == LIXH_STATE_PLAYING) atomic_store_explicit(&p->state, LIXH_STATE_STOPPED, memory_order_release);
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
        p->chase_mode = CHASE_NONE;
        p->chase_drop_streak = 0;
        p->video_join_grace_until_ms = now_ms() + 3000;
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
    /* Prefer video chase lag when picture is on; else audio clock drift.
       Neither is absolute live-site latency. */
    int64_t lag = 0;
    int sink = atomic_load_explicit(&p->video_sink, memory_order_acquire);
    int64_t now = now_ms();
    int in_grace = (p->video_join_grace_until_ms > 0 && now < p->video_join_grace_until_ms);
    if (sink && out->last_video_pts_ms != AV_NOPTS_VALUE) {
        /* During chase, frozen present PTS inflates wall-drift — use demux tip. */
        int64_t tip = atomic_load_explicit(&p->latest_video_pkt_pts_ms, memory_order_acquire);
        if (p->chase_mode != CHASE_NONE && tip != AV_NOPTS_VALUE) {
            int64_t behind = tip - out->last_video_pts_ms;
            if (behind < 0) behind = 0;
            lag = behind;
        } else {
            lag = video_chase_lag_ms(p, out->last_video_pts_ms);
        }
    } else if (sink) {
        /* Picture on but no presented frame yet — do not show audio drift as 追. */
        lag = 0;
    } else if (out->last_audio_pts_ms != AV_NOPTS_VALUE) {
        int64_t tip = atomic_load_explicit(&p->latest_audio_pkt_pts_ms, memory_order_acquire);
        int64_t tip_behind = 0;
        if (tip != AV_NOPTS_VALUE && tip >= out->last_audio_pts_ms) {
            tip_behind = tip - out->last_audio_pts_ms;
        }
        int64_t drift = audio_drift_ms(p, out->last_audio_pts_ms);
        lag = tip_behind > drift ? tip_behind : drift;
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
