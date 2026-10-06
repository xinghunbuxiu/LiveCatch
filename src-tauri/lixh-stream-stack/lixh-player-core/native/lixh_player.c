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
#ifdef LIXH_MACOS
#include <libavutil/hwcontext_videotoolbox.h>
#endif

typedef struct LixhPlayer {
    LixhCallbacks cb;
    AVFormatContext *fmt;
    AVCodecContext *vdec;
    AVCodecContext *adec;
    AVBufferRef *hw_device;
    SwrContext *swr;
    int vstream;
    int astream;
    enum AVPixelFormat hw_pix_fmt;
    int hw_kind;
    atomic_int state;
    atomic_int stop;
    atomic_int playing;
    int opened;
    char *url;
    atomic_int_fast64_t base_wall_ms;
    atomic_int_fast64_t first_pts_ms;
    atomic_int_fast64_t last_video_pts_ms;
    atomic_int_fast64_t last_audio_pts_ms;
    atomic_uint_fast64_t video_frames;
    atomic_uint_fast64_t audio_frames;
    atomic_uint_fast64_t dropped_frames;
    atomic_uint_fast64_t reconnects;
    int64_t target_latency_ms;
    int64_t max_latency_ms;
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
#elif defined(LIXH_MACOS)
    enum AVHWDeviceType type = AV_HWDEVICE_TYPE_VIDEOTOOLBOX;
    p->hw_pix_fmt = AV_PIX_FMT_VIDEOTOOLBOX;
    p->hw_kind = LIXH_VIDEO_VIDEOTOOLBOX;
#else
    return AVERROR(ENOSYS);
#endif
    int rc = av_hwdevice_ctx_create(&p->hw_device, type, NULL, NULL, 0);
    if (rc < 0) {
        p->hw_device = NULL;
        p->hw_kind = LIXH_VIDEO_SOFTWARE;
        return rc;
    }
    return 0;
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
    av_dict_set(&opts, "fflags", "nobuffer+discardcorrupt", 0);
    av_dict_set(&opts, "flags", "low_delay", 0);
    av_dict_set(&opts, "probesize", "65536", 0);
    av_dict_set(&opts, "analyzeduration", "200000", 0);
    av_dict_set(&opts, "rw_timeout", "3000000", 0);
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

static void deliver_video(LixhPlayer *p, AVFrame *f, AVRational tb) {
    int64_t pts = frame_pts_ms(f, tb);
    if (pts == AV_NOPTS_VALUE) return;
    if (atomic_load_explicit(&p->first_pts_ms, memory_order_acquire) == AV_NOPTS_VALUE) atomic_store_explicit(&p->first_pts_ms, pts, memory_order_release);
    int64_t last_pts = atomic_load_explicit(&p->last_video_pts_ms, memory_order_acquire);
    if (last_pts != AV_NOPTS_VALUE && pts < last_pts - 1000) return;
    int64_t wall_elapsed = now_ms() - atomic_load_explicit(&p->base_wall_ms, memory_order_acquire);
    int64_t media_elapsed = pts - atomic_load_explicit(&p->first_pts_ms, memory_order_acquire);
    int64_t live_lag = wall_elapsed - media_elapsed;
    if (live_lag > p->max_latency_ms) {
        atomic_fetch_add_explicit(&p->dropped_frames, 1, memory_order_relaxed);
        return;
    }
    atomic_store_explicit(&p->last_video_pts_ms, pts, memory_order_release);
    atomic_fetch_add_explicit(&p->video_frames, 1, memory_order_relaxed);
    if (!p->cb.on_video) return;
    if (f->format == AV_PIX_FMT_D3D11) {
#ifdef LIXH_WINDOWS
        LixhNativeFrame nf = { LIXH_VIDEO_D3D11, f->width, f->height, f->data[0], (intptr_t)f->data[1], f };
        p->cb.on_video(p->cb.opaque, nf.kind, nf.width, nf.height, pts, 0, &nf);
#endif
    } else if (f->format == AV_PIX_FMT_VIDEOTOOLBOX) {
#ifdef LIXH_MACOS
        LixhNativeFrame nf = { LIXH_VIDEO_VIDEOTOOLBOX, f->width, f->height, f->data[3], 0, f };
        p->cb.on_video(p->cb.opaque, nf.kind, nf.width, nf.height, pts, 0, &nf);
#endif
    } else {
        LixhNativeFrame nf = { LIXH_VIDEO_SOFTWARE, f->width, f->height, f, 0, f };\n        p->cb.on_video(p->cb.opaque, nf.kind, nf.width, nf.height, pts, 0, &nf);
    }
}

static void deliver_audio(LixhPlayer *p, AVFrame *f, AVRational tb) {
    int64_t pts = frame_pts_ms(f, tb);
    if (pts == AV_NOPTS_VALUE || !p->cb.on_audio) return;
    atomic_store_explicit(&p->last_audio_pts_ms, pts, memory_order_release);
    atomic_fetch_add_explicit(&p->audio_frames, 1, memory_order_relaxed);
    if (!p->swr) return;
    int out_samples = av_rescale_rnd(swr_get_delay(p->swr, p->sample_rate) + f->nb_samples,
                                     p->sample_rate, p->sample_rate, AV_ROUND_UP);
    float *out = (float *)av_malloc_array((size_t)out_samples * (size_t)p->channels, sizeof(float));
    if (!out) return;
    uint8_t *dst[1] = { (uint8_t *)out };
    int n = swr_convert(p->swr, dst, out_samples, (const uint8_t **)f->extended_data, f->nb_samples);
    if (n > 0) p->cb.on_audio(p->cb.opaque, p->sample_rate, p->channels, AV_SAMPLE_FMT_FLT, pts, out, n);
    av_free(out);
}

static int decode_packet(LixhPlayer *p, AVPacket *pkt) {
    AVCodecContext *dec = pkt->stream_index == p->vstream ? p->vdec : p->adec;
    if (!dec) return 0;
    int rc = avcodec_send_packet(dec, pkt);
    if (rc < 0 && rc != AVERROR(EAGAIN)) return rc;
    AVFrame *f = av_frame_alloc();
    if (!f) return AVERROR(ENOMEM);
    AVRational tb = p->fmt->streams[pkt->stream_index]->time_base;
    while (!atomic_load_explicit(&p->stop, memory_order_acquire)) {
        rc = avcodec_receive_frame(dec, f);
        if (rc == AVERROR(EAGAIN) || rc == AVERROR_EOF) break;
        if (rc < 0) { av_frame_unref(f); break; }
        if (pkt->stream_index == p->vstream) deliver_video(p, f, tb);
        else deliver_audio(p, f, tb);
        av_frame_unref(f);
    }
    av_frame_free(&f);
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
    atomic_init(&p->video_frames, 0);
    atomic_init(&p->audio_frames, 0);
    atomic_init(&p->dropped_frames, 0);
    atomic_init(&p->reconnects, 0);
    atomic_init(&p->first_pts_ms, AV_NOPTS_VALUE);
    atomic_init(&p->last_video_pts_ms, AV_NOPTS_VALUE);
    atomic_init(&p->last_audio_pts_ms, AV_NOPTS_VALUE);
    p->target_latency_ms = 650;
    p->max_latency_ms = 1400;
    return p;
}

void lixh_player_destroy(void *opaque) {
    LixhPlayer *p = (LixhPlayer *)opaque;
    if (!p) return;
    lixh_player_stop(p);
    free_player_media(p);
    free(p->url);
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
    atomic_store_explicit(&p->first_pts_ms, AV_NOPTS_VALUE, memory_order_release);
    atomic_store_explicit(&p->last_video_pts_ms, AV_NOPTS_VALUE, memory_order_release);
    atomic_store_explicit(&p->last_audio_pts_ms, AV_NOPTS_VALUE, memory_order_release);
    atomic_store_explicit(&p->base_wall_ms, now_ms(), memory_order_release);
    int rc = open_input(p);
    if (rc < 0) { atomic_store_explicit(&p->state, LIXH_STATE_ERROR, memory_order_release); emit(p, LIXH_EVT_ERROR, rc, av_err2str(rc)); free_player_media(p); }
    return rc;
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
                atomic_store_explicit(&p->first_pts_ms, AV_NOPTS_VALUE, memory_order_release);
                atomic_store_explicit(&p->last_video_pts_ms, AV_NOPTS_VALUE, memory_order_release);
                atomic_store_explicit(&p->base_wall_ms, now_ms(), memory_order_release);
                rc = 0; continue;
            }
            break;
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
    int64_t first_pts = atomic_load_explicit(&p->first_pts_ms, memory_order_acquire);
    int64_t last_video_pts = atomic_load_explicit(&p->last_video_pts_ms, memory_order_acquire);
    if (first_pts != AV_NOPTS_VALUE && last_video_pts != AV_NOPTS_VALUE) {
        int64_t wall_elapsed = now_ms() - atomic_load_explicit(&p->base_wall_ms, memory_order_acquire);
        int64_t media_elapsed = last_video_pts - first_pts;
        int64_t lag = wall_elapsed - media_elapsed;
        out->input_buffer_ms = lag > 0 ? lag : 0;
    }
    out->decode_hw = p->hw_kind;
    return 0;
}
