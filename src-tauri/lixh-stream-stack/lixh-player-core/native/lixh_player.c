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
    int opened;
    char *url;
    char *http_headers;
    atomic_int_fast64_t base_wall_ms;
    atomic_int_fast64_t first_pts_ms;
    atomic_int_fast64_t last_video_pts_ms;
    atomic_int_fast64_t last_audio_pts_ms;
    atomic_uint_fast64_t video_frames;
    atomic_uint_fast64_t audio_frames;
    atomic_uint_fast64_t dropped_frames;
    atomic_uint_fast64_t reconnects;
    atomic_uint_fast64_t bytes_read;
    atomic_int video_width;
    atomic_int video_height;
    int64_t target_latency_ms;
    int64_t max_latency_ms;
    int chase_drop_streak;
    /* Consecutive on_video <0 before committing to demux-thread SW download. */
    int d3d11_fail_streak;
    int sample_rate;
    int channels;
} LixhPlayer;

static void emit(LixhPlayer *p, int type, int code, const char *msg) {
    if (p && p->cb.on_event) p->cb.on_event(p->cb.opaque, type, code, msg ? msg : "");
}

static int64_t now_ms(void) { return av_gettime_relative() / 1000; }

static int interrupt_cb(void *opaque) {
    LixhPlayer *p = (LixhPlayer *)opaque;
    return p && atomic_load_explicit(&p->stop, memory_order_acquire) ? 1 : 0;
}

static void free_player_media(LixhPlayer *p) {
    if (p->swr) swr_free(&p->swr);
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
    /* MediaCodec decode → CPU transfer → SurfaceTexture present. */
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
        rc = avcodec_open2(ctx, codec, NULL);
        if (rc < 0 && p->hw_device) {
            av_buffer_unref(&ctx->hw_device_ctx);
            p->hw_kind = LIXH_VIDEO_SOFTWARE;
            ctx->get_format = NULL;
            rc = avcodec_open2(ctx, codec, NULL);
        }
    } else {
        rc = avcodec_open2(ctx, codec, NULL);
    }
    if (rc < 0) { avcodec_free_context(&ctx); return rc; }
    if (video) p->vdec = ctx; else p->adec = ctx;
    return 0;
}

static int open_input(LixhPlayer *p) {
    AVDictionary *opts = NULL;
    av_dict_set(&opts, "fflags", "nobuffer+discardcorrupt+flush_packets", 0);
    av_dict_set(&opts, "max_delay", "0", 0);
    av_dict_set(&opts, "flags", "low_delay", 0);
    /* Tight probe for faster join. */
    av_dict_set(&opts, "probesize", "327680", 0);
    av_dict_set(&opts, "analyzeduration", "300000", 0);
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
    if (p->vstream < 0) return AVERROR_STREAM_NOT_FOUND;
    setup_hw(p);
    rc = open_decoder(p, p->fmt->streams[p->vstream], 1);
    if (rc < 0) return rc;
    if (p->astream >= 0) {
        rc = open_decoder(p, p->fmt->streams[p->astream], 0);
        if (rc < 0) p->astream = -1;
    }
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

/* Video-only chase. Soft-drop skips GPU present (keeps demux/audio moving);
   hard re-anchor when lag exceeds max. Audio never uses this. */
static int live_chase_should_drop(LixhPlayer *p, int64_t pts, int is_key) {
    if (atomic_load_explicit(&p->first_pts_ms, memory_order_acquire) == AV_NOPTS_VALUE) {
        atomic_store_explicit(&p->first_pts_ms, pts, memory_order_release);
        atomic_store_explicit(&p->base_wall_ms, now_ms(), memory_order_release);
        p->chase_drop_streak = 0;
        return 0;
    }
    int64_t wall_elapsed = now_ms() - atomic_load_explicit(&p->base_wall_ms, memory_order_acquire);
    int64_t media_elapsed = pts - atomic_load_explicit(&p->first_pts_ms, memory_order_acquire);
    int64_t live_lag = wall_elapsed - media_elapsed;
    if (live_lag > p->max_latency_ms) {
        atomic_store_explicit(&p->first_pts_ms, pts, memory_order_release);
        atomic_store_explicit(&p->base_wall_ms, now_ms(), memory_order_release);
        p->chase_drop_streak = 0;
        atomic_fetch_add_explicit(&p->dropped_frames, 1, memory_order_relaxed);
        return 1;
    }
    if (p->target_latency_ms > 0 && live_lag > p->target_latency_ms) {
        /* Prefer dropping non-keyframes so we snap to the next IDR near live. */
        if (!is_key || p->chase_drop_streak < 8) {
            p->chase_drop_streak++;
            atomic_fetch_add_explicit(&p->dropped_frames, 1, memory_order_relaxed);
            return 1;
        }
    }
    p->chase_drop_streak = 0;
    return 0;
}

static void deliver_video(LixhPlayer *p, AVFrame *f, AVRational tb) {
    int64_t pts = frame_pts_ms(f, tb);
    if (pts == AV_NOPTS_VALUE) return;
    int64_t last_pts = atomic_load_explicit(&p->last_video_pts_ms, memory_order_acquire);
    if (last_pts != AV_NOPTS_VALUE && pts < last_pts - 1000) return;
    int is_key = 0;
#if LIBAVUTIL_VERSION_MAJOR >= 58
    is_key = (f->flags & AV_FRAME_FLAG_KEY) != 0;
#else
    is_key = f->key_frame;
#endif
    if (live_chase_should_drop(p, pts, is_key)) return;
    atomic_store_explicit(&p->last_video_pts_ms, pts, memory_order_release);
    atomic_fetch_add_explicit(&p->video_frames, 1, memory_order_relaxed);
    if (f->width > 0 && f->height > 0) {
        atomic_store_explicit(&p->video_width, f->width, memory_order_relaxed);
        atomic_store_explicit(&p->video_height, f->height, memory_order_relaxed);
    }
    if (!p->cb.on_video) return;
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
        /* Transfer to SW for ANativeWindow/RGBA present (direct Surface later). */
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
            /* Silent drop — ERROR here was mistaken for play failure on UI. */
        }
        av_frame_unref(sw);
#endif
    } else {
        LixhNativeFrame nf = { LIXH_VIDEO_SOFTWARE, f->width, f->height, f, 0, f };
        p->cb.on_video(p->cb.opaque, nf.kind, nf.width, nf.height, pts, 0, &nf);
    }
}

static void deliver_audio(LixhPlayer *p, AVFrame *f, AVRational tb) {
    int64_t pts = frame_pts_ms(f, tb);
    if (pts == AV_NOPTS_VALUE || !p->cb.on_audio) return;
    /* Never soft-chase audio: video soft-drops were starving PCM and freezing
       listen-only / return-from-video. Live edge is trimmed in WASAPI queue. */
    if (atomic_load_explicit(&p->first_pts_ms, memory_order_acquire) == AV_NOPTS_VALUE) {
        atomic_store_explicit(&p->first_pts_ms, pts, memory_order_release);
        atomic_store_explicit(&p->base_wall_ms, now_ms(), memory_order_release);
    }
    atomic_store_explicit(&p->last_audio_pts_ms, pts, memory_order_release);
    atomic_fetch_add_explicit(&p->audio_frames, 1, memory_order_relaxed);
    if (!p->swr) return;
    int out_samples = av_rescale_rnd(swr_get_delay(p->swr, p->sample_rate) + f->nb_samples,
                                     p->sample_rate, p->sample_rate, AV_ROUND_UP);
    size_t needed = (size_t)out_samples * (size_t)p->channels;
    if (needed > p->audio_out_capacity) {
        float *grown = (float *)av_realloc_array(p->audio_out, needed, sizeof(float));
        if (!grown) return;
        p->audio_out = grown;
        p->audio_out_capacity = needed;
    }
    uint8_t *dst[1] = { (uint8_t *)p->audio_out };
    int n = swr_convert(p->swr, dst, out_samples, (const uint8_t **)f->extended_data, f->nb_samples);
    if (n > 0) p->cb.on_audio(p->cb.opaque, p->sample_rate, p->channels, AV_SAMPLE_FMT_FLT, pts, p->audio_out, n);
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

void *lixh_player_create(const LixhCallbacks *cb) {
    LixhPlayer *p = (LixhPlayer *)calloc(1, sizeof(*p));
    if (!p) return NULL;
    if (cb) p->cb = *cb;
    p->vstream = p->astream = -1;
    atomic_init(&p->state, LIXH_STATE_IDLE);
    atomic_init(&p->stop, 0);
    atomic_init(&p->playing, 0);
    atomic_init(&p->direct_d3d11, 0);
    atomic_init(&p->video_sink, 1);
    atomic_init(&p->flush_video_req, 0);
    atomic_init(&p->video_frames, 0);
    atomic_init(&p->audio_frames, 0);
    atomic_init(&p->dropped_frames, 0);
    atomic_init(&p->reconnects, 0);
    atomic_init(&p->bytes_read, 0);
    atomic_init(&p->video_width, 0);
    atomic_init(&p->video_height, 0);
    atomic_init(&p->first_pts_ms, AV_NOPTS_VALUE);
    atomic_init(&p->last_video_pts_ms, AV_NOPTS_VALUE);
    atomic_init(&p->last_audio_pts_ms, AV_NOPTS_VALUE);
    p->target_latency_ms = 400;
    p->max_latency_ms = 900;
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
    atomic_store_explicit(&p->first_pts_ms, AV_NOPTS_VALUE, memory_order_release);
    atomic_store_explicit(&p->last_video_pts_ms, AV_NOPTS_VALUE, memory_order_release);
    atomic_store_explicit(&p->last_audio_pts_ms, AV_NOPTS_VALUE, memory_order_release);
    int rc = open_input(p);
    if (rc < 0) { atomic_store_explicit(&p->state, LIXH_STATE_ERROR, memory_order_release); emit(p, LIXH_EVT_ERROR, rc, av_err2str(rc)); free_player_media(p); return rc; }
    atomic_store_explicit(&p->base_wall_ms, now_ms(), memory_order_release);
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
                atomic_store_explicit(&p->first_pts_ms, AV_NOPTS_VALUE, memory_order_release);
                atomic_store_explicit(&p->last_video_pts_ms, AV_NOPTS_VALUE, memory_order_release);
                atomic_store_explicit(&p->base_wall_ms, now_ms(), memory_order_release);
                p->d3d11_fail_streak = 0;
                rc = 0; continue;
            }
            break;
        }
        if (atomic_exchange_explicit(&p->flush_video_req, 0, memory_order_acq_rel)) {
            if (p->vdec) avcodec_flush_buffers(p->vdec);
            atomic_store_explicit(&p->direct_d3d11, 0, memory_order_release);
            p->d3d11_fail_streak = 0;
        }
        if (pkt->size > 0) {
            atomic_fetch_add_explicit(&p->bytes_read, (uint64_t)pkt->size, memory_order_relaxed);
        }
        if (pkt->stream_index == p->vstream &&
            !atomic_load_explicit(&p->video_sink, memory_order_acquire)) {
            av_packet_unref(pkt);
            continue;
        }
        if (pkt->stream_index == p->vstream || pkt->stream_index == p->astream) decode_packet(p, pkt);
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

void lixh_player_set_video_sink(void *opaque, int enabled) {
    LixhPlayer *p = (LixhPlayer *)opaque;
    if (!p) return;
    int on = enabled ? 1 : 0;
    int prev = atomic_exchange_explicit(&p->video_sink, on, memory_order_acq_rel);
    /* Never touch AVCodecContext from the UI thread — play loop will flush. */
    if (on && !prev) {
        atomic_store_explicit(&p->flush_video_req, 1, memory_order_release);
        /* Listen-only audio may have anchored first_pts; clear so the first
           delivered video frame re-bases live chase instead of mass-dropping. */
        atomic_store_explicit(&p->first_pts_ms, AV_NOPTS_VALUE, memory_order_release);
        atomic_store_explicit(&p->direct_d3d11, 0, memory_order_release);
        p->d3d11_fail_streak = 0;
    }
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
    int64_t first_pts = atomic_load_explicit(&p->first_pts_ms, memory_order_acquire);
    int64_t last_pts = out->last_video_pts_ms;
    if (last_pts == AV_NOPTS_VALUE) last_pts = out->last_audio_pts_ms;
    if (first_pts != AV_NOPTS_VALUE && last_pts != AV_NOPTS_VALUE) {
        int64_t wall_elapsed = now_ms() - atomic_load_explicit(&p->base_wall_ms, memory_order_acquire);
        int64_t media_elapsed = last_pts - first_pts;
        int64_t lag = wall_elapsed - media_elapsed;
        /* Clamp: after re-anchor lag≈0; negative = clock skew. */
        if (lag < 0) lag = 0;
        if (lag > 60000) lag = 60000;
        out->input_buffer_ms = lag;
    }
    out->decode_hw = p->hw_kind;
    return 0;
}
