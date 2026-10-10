#include <aaudio/AAudio.h>
#include <android/log.h>
#include <android/native_window.h>
#include <android/native_window_jni.h>
#include <jni.h>

#include <atomic>
#include <chrono>
#include <cstring>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

extern "C" {
#include "lixh_player.h"
#include <libavutil/frame.h>
#include <libavutil/imgutils.h>
#include <libswscale/swscale.h>
}

#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, "lixh", __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, "lixh", __VA_ARGS__)

namespace {

constexpr int kRingCap = 48000 * 2 * 2;

class AudioOut {
 public:
  ~AudioOut() { Stop(); }

  void Push(const float* samples, int frames, int channels, int rate) {
    if (!samples || frames <= 0 || channels <= 0) return;
    std::lock_guard<std::mutex> lock(mu_);
    if (!Ensure(rate, channels)) return;
    int n = frames * channels;
    if (n > kRingCap / 2) n = kRingCap / 2;
    while (count_ + n > kRingCap) {
      int drop = ch_ * (rate_ / 50);
      if (drop < 1) drop = n;
      if (drop > count_) drop = count_;
      r_ = (r_ + drop) % kRingCap;
      count_ -= drop;
    }
    int off = 0;
    while (off < n) {
      int chunk = n - off;
      int to_end = kRingCap - w_;
      if (chunk > to_end) chunk = to_end;
      memcpy(ring_.data() + w_, samples + off, (size_t)chunk * sizeof(float));
      w_ = (w_ + chunk) % kRingCap;
      count_ += chunk;
      off += chunk;
    }
  }

  void Stop() {
    std::lock_guard<std::mutex> lock(mu_);
    if (stream_) {
      AAudioStream_requestStop(stream_);
      AAudioStream_close(stream_);
      stream_ = nullptr;
    }
    r_ = w_ = count_ = 0;
  }

  int QueuedMs() const {
    std::lock_guard<std::mutex> lock(mu_);
    if (rate_ <= 0 || ch_ <= 0) return 0;
    return (int)((count_ / ch_) * 1000L / rate_);
  }

 private:
  static aaudio_data_callback_result_t Callback(AAudioStream* /*s*/, void* user,
                                                void* audio, int32_t num_frames) {
    auto* self = static_cast<AudioOut*>(user);
    return self->OnAudio(static_cast<float*>(audio), num_frames);
  }

  aaudio_data_callback_result_t OnAudio(float* dst, int32_t num_frames) {
    std::lock_guard<std::mutex> lock(mu_);
    int need = num_frames * ch_;
    int got = 0;
    while (got < need && count_ > 0) {
      int n = need - got;
      if (n > count_) n = count_;
      int to_end = kRingCap - r_;
      if (n > to_end) n = to_end;
      memcpy(dst + got, ring_.data() + r_, (size_t)n * sizeof(float));
      r_ = (r_ + n) % kRingCap;
      count_ -= n;
      got += n;
    }
    if (got < need) memset(dst + got, 0, (size_t)(need - got) * sizeof(float));
    return AAUDIO_CALLBACK_RESULT_CONTINUE;
  }

  bool Ensure(int rate, int ch) {
    if (stream_ && rate_ == rate && ch_ == ch) return true;
    if (stream_) {
      AAudioStream_requestStop(stream_);
      AAudioStream_close(stream_);
      stream_ = nullptr;
    }
    rate_ = rate > 0 ? rate : 48000;
    ch_ = ch > 0 ? ch : 2;
    ring_.assign(kRingCap, 0.f);
    r_ = w_ = count_ = 0;
    AAudioStreamBuilder* b = nullptr;
    if (AAudio_createStreamBuilder(&b) != AAUDIO_OK) return false;
    AAudioStreamBuilder_setDirection(b, AAUDIO_DIRECTION_OUTPUT);
    AAudioStreamBuilder_setSharingMode(b, AAUDIO_SHARING_MODE_SHARED);
    AAudioStreamBuilder_setFormat(b, AAUDIO_FORMAT_PCM_FLOAT);
    AAudioStreamBuilder_setChannelCount(b, ch_);
    AAudioStreamBuilder_setSampleRate(b, rate_);
    AAudioStreamBuilder_setPerformanceMode(b, AAUDIO_PERFORMANCE_MODE_LOW_LATENCY);
    AAudioStreamBuilder_setDataCallback(b, Callback, this);
    aaudio_result_t rc = AAudioStreamBuilder_openStream(b, &stream_);
    AAudioStreamBuilder_delete(b);
    if (rc != AAUDIO_OK || !stream_) return false;
    return AAudioStream_requestStart(stream_) == AAUDIO_OK;
  }

  mutable std::mutex mu_;
  std::vector<float> ring_ = std::vector<float>(kRingCap);
  int r_ = 0, w_ = 0, count_ = 0, rate_ = 48000, ch_ = 2;
  AAudioStream* stream_ = nullptr;
};

class Session {
 public:
  Session() = default;
  ~Session() {
    Stop();
    DetachSurface();
  }

  void AttachSurface(JNIEnv* env, jobject surface) {
    std::lock_guard<std::mutex> lock(win_mu_);
    if (window_) {
      ANativeWindow_release(window_);
      window_ = nullptr;
    }
    if (surface) {
      window_ = ANativeWindow_fromSurface(env, surface);
    }
    last_present_ = {};
  }

  void DetachSurface() {
    std::lock_guard<std::mutex> lock(win_mu_);
    if (sws_) {
      sws_freeContext(sws_);
      sws_ = nullptr;
    }
    sws_w_ = sws_h_ = 0;
    sws_fmt_ = AV_PIX_FMT_NONE;
    if (window_) {
      ANativeWindow_release(window_);
      window_ = nullptr;
    }
  }

  bool Open(const std::string& url, const std::string& headers) {
    Stop();
    LixhCallbacks cb{};
    cb.opaque = this;
    cb.on_video = [](void* o, int kind, int w, int h, int64_t, int64_t,
                     const LixhNativeFrame* frame) -> int {
      return static_cast<Session*>(o)->OnVideo(kind, w, h, frame);
    };
    cb.on_audio = [](void* o, int rate, int ch, int, int64_t, const float* s,
                     int n) {
      auto* self = static_cast<Session*>(o);
      {
        std::lock_guard<std::mutex> lock(self->mu_);
        if (!self->player_) return;
      }
      self->audio_frames_.fetch_add(1);
      self->audio_.Push(s, n, ch, rate);
    };
    cb.on_event = [](void* o, int type, int, const char* msg) {
      if (type != LIXH_EVT_ERROR || !msg) return;
      static_cast<Session*>(o)->SetError(msg);
    };
    void* p = lixh_player_create(&cb);
    if (!p) {
      SetError("lixh_player_create failed");
      return false;
    }
    if (!headers.empty()) lixh_player_set_headers(p, headers.c_str());
    if (lixh_player_open(p, url.c_str()) < 0) {
      SetError("lixh_player_open failed");
      lixh_player_destroy(p);
      return false;
    }
    lixh_player_set_latency(p, 200, 700);
    lixh_player_set_video_sink(p, video_enabled_.load() ? 1 : 0);
    std::lock_guard<std::mutex> lock(mu_);
    player_ = p;
    LOGI("open url=%zu", url.size());
    return true;
  }

  bool Play() {
    void* p = nullptr;
    {
      std::lock_guard<std::mutex> lock(mu_);
      if (!player_) {
        SetError("player not open");
        return false;
      }
      if (play_thread_.joinable()) {
        SetError("already playing");
        return false;
      }
      p = player_;
      play_thread_ = std::thread([this, p]() {
        if (lixh_player_play(p) < 0) SetError("lixh_player_play failed");
      });
    }
    LOGI("play");
    return true;
  }

  void Stop() {
    void* p = nullptr;
    std::thread th;
    {
      std::lock_guard<std::mutex> lock(mu_);
      p = player_;
      player_ = nullptr;
      if (play_thread_.joinable()) th = std::move(play_thread_);
    }
    if (p) lixh_player_stop(p);
    if (th.joinable()) th.join();
    if (p) lixh_player_destroy(p);
    audio_.Stop();
  }

  void SetVideoEnabled(bool on) {
    video_enabled_.store(on);
    void* p = nullptr;
    {
      std::lock_guard<std::mutex> lock(mu_);
      p = player_;
    }
    if (p) lixh_player_set_video_sink(p, on ? 1 : 0);
  }

  std::string last_error() const {
    std::lock_guard<std::mutex> lock(mu_);
    return last_error_;
  }

  void FillStats(JNIEnv* env, jobject map) {
    auto putL = [&](const char* k, int64_t v) {
      jclass c = env->GetObjectClass(map);
      jmethodID m = env->GetMethodID(c, "put",
                                     "(Ljava/lang/Object;Ljava/lang/Object;)Ljava/lang/Object;");
      jclass longCls = env->FindClass("java/lang/Long");
      jmethodID valueOf = env->GetStaticMethodID(longCls, "valueOf", "(J)Ljava/lang/Long;");
      env->CallObjectMethod(map, m, env->NewStringUTF(k),
                            env->CallStaticObjectMethod(longCls, valueOf, v));
    };
    auto putI = [&](const char* k, int v) { putL(k, v); };
    auto putS = [&](const char* k, const std::string& v) {
      jclass c = env->GetObjectClass(map);
      jmethodID m = env->GetMethodID(c, "put",
                                     "(Ljava/lang/Object;Ljava/lang/Object;)Ljava/lang/Object;");
      env->CallObjectMethod(map, m, env->NewStringUTF(k), env->NewStringUTF(v.c_str()));
    };
    putL("videoFrames", (int64_t)video_frames_.load());
    putL("presentOk", (int64_t)present_ok_.load());
    putL("audioFrames", (int64_t)audio_frames_.load());
    putI("audioQueueMs", audio_.QueuedMs());
    uint64_t dropped = 0, bread = 0;
    int64_t lag = 0;
    int vw = 0, vh = 0, decode_hw = 0;
    std::string err;
    {
      std::lock_guard<std::mutex> lock(mu_);
      err = last_error_;
      if (player_) {
        LixhStats core{};
        if (lixh_player_get_stats(player_, &core) == 0) {
          dropped = core.dropped_frames;
          bread = core.bytes_read;
          lag = core.input_buffer_ms;
          vw = core.video_width;
          vh = core.video_height;
          decode_hw = core.decode_hw;
        }
      }
    }
    putI("decodeHw", decode_hw);
    putL("droppedFrames", (int64_t)dropped);
    putL("bytesRead", (int64_t)bread);
    putL("lagMs", lag);
    putI("videoWidth", vw);
    putI("videoHeight", vh);
    putS("lastError", err);
  }

 private:
  int OnVideo(int kind, int width, int height, const LixhNativeFrame* frame) {
    video_frames_.fetch_add(1);
    if (!video_enabled_.load()) return 1;
    if (kind != LIXH_VIDEO_SOFTWARE || !frame || !frame->handle0) return 1;
    if (width <= 0 || height <= 0) return -1;

    auto now = std::chrono::steady_clock::now();
    if (last_present_.time_since_epoch().count() != 0) {
      auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(now - last_present_)
                    .count();
      if (ms < 15) return 1;
    }

    ANativeWindow* win = nullptr;
    {
      std::lock_guard<std::mutex> lock(win_mu_);
      win = window_;
      if (win) ANativeWindow_acquire(win);
    }
    if (!win) return 1;

    const AVFrame* src = static_cast<const AVFrame*>(frame->handle0);
    ANativeWindow_setBuffersGeometry(win, width, height, WINDOW_FORMAT_RGBA_8888);
    ANativeWindow_Buffer buf{};
    if (ANativeWindow_lock(win, &buf, nullptr) != 0) {
      ANativeWindow_release(win);
      return -1;
    }

    int ok = -1;
    {
      std::lock_guard<std::mutex> lock(win_mu_);
      if (!sws_ || sws_w_ != width || sws_h_ != height || sws_fmt_ != src->format) {
        if (sws_) sws_freeContext(sws_);
        sws_ = sws_getContext(width, height, (AVPixelFormat)src->format, width, height,
                              AV_PIX_FMT_RGBA, SWS_BILINEAR, nullptr, nullptr, nullptr);
        sws_w_ = width;
        sws_h_ = height;
        sws_fmt_ = src->format;
      }
      if (sws_ && buf.bits) {
        uint8_t* dst_data[4] = {static_cast<uint8_t*>(buf.bits), nullptr, nullptr, nullptr};
        int dst_linesize[4] = {buf.stride * 4, 0, 0, 0};
        sws_scale(sws_, src->data, src->linesize, 0, height, dst_data, dst_linesize);
        ok = 0;
      }
    }

    ANativeWindow_unlockAndPost(win);
    ANativeWindow_release(win);
    if (ok == 0) {
      last_present_ = now;
      present_ok_.fetch_add(1);
    }
    return ok;
  }

  void SetError(const std::string& msg) {
    std::lock_guard<std::mutex> lock(mu_);
    last_error_ = msg;
    LOGE("%s", msg.c_str());
  }

  mutable std::mutex mu_;
  mutable std::mutex win_mu_;
  void* player_ = nullptr;
  std::thread play_thread_;
  AudioOut audio_;
  ANativeWindow* window_ = nullptr;
  SwsContext* sws_ = nullptr;
  int sws_w_ = 0, sws_h_ = 0, sws_fmt_ = AV_PIX_FMT_NONE;
  std::chrono::steady_clock::time_point last_present_{};
  std::string last_error_;
  std::atomic<uint64_t> video_frames_{0};
  std::atomic<uint64_t> audio_frames_{0};
  std::atomic<uint64_t> present_ok_{0};
  std::atomic<bool> video_enabled_{false};
};

}  // namespace

extern "C" JNIEXPORT jlong JNICALL
Java_com_livecatch_lixh_1player_LixhPlayerPlugin_nativeCreate(JNIEnv*, jobject) {
  return reinterpret_cast<jlong>(new Session());
}

extern "C" JNIEXPORT void JNICALL
Java_com_livecatch_lixh_1player_LixhPlayerPlugin_nativeDestroy(JNIEnv*, jobject,
                                                              jlong ptr) {
  delete reinterpret_cast<Session*>(ptr);
}

extern "C" JNIEXPORT jboolean JNICALL
Java_com_livecatch_lixh_1player_LixhPlayerPlugin_nativeOpen(JNIEnv* env, jobject,
                                                           jlong ptr, jstring jurl,
                                                           jstring jheaders) {
  auto* s = reinterpret_cast<Session*>(ptr);
  if (!s || !jurl) return JNI_FALSE;
  const char* url = env->GetStringUTFChars(jurl, nullptr);
  std::string headers;
  if (jheaders) {
    const char* h = env->GetStringUTFChars(jheaders, nullptr);
    headers = h ? h : "";
    env->ReleaseStringUTFChars(jheaders, h);
  }
  bool ok = s->Open(url ? url : "", headers);
  env->ReleaseStringUTFChars(jurl, url);
  return ok ? JNI_TRUE : JNI_FALSE;
}

extern "C" JNIEXPORT jboolean JNICALL
Java_com_livecatch_lixh_1player_LixhPlayerPlugin_nativePlay(JNIEnv*, jobject,
                                                           jlong ptr) {
  auto* s = reinterpret_cast<Session*>(ptr);
  return s && s->Play() ? JNI_TRUE : JNI_FALSE;
}

extern "C" JNIEXPORT void JNICALL
Java_com_livecatch_lixh_1player_LixhPlayerPlugin_nativeStop(JNIEnv*, jobject,
                                                           jlong ptr) {
  auto* s = reinterpret_cast<Session*>(ptr);
  if (s) s->Stop();
}

extern "C" JNIEXPORT void JNICALL
Java_com_livecatch_lixh_1player_LixhPlayerPlugin_nativeSetVideoEnabled(JNIEnv*,
                                                                     jobject,
                                                                     jlong ptr,
                                                                     jboolean on) {
  auto* s = reinterpret_cast<Session*>(ptr);
  if (s) s->SetVideoEnabled(on == JNI_TRUE);
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_livecatch_lixh_1player_LixhPlayerPlugin_nativeLastError(JNIEnv* env,
                                                                jobject,
                                                                jlong ptr) {
  auto* s = reinterpret_cast<Session*>(ptr);
  std::string e = s ? s->last_error() : "no session";
  return env->NewStringUTF(e.c_str());
}

extern "C" JNIEXPORT void JNICALL
Java_com_livecatch_lixh_1player_LixhPlayerPlugin_nativeFillStats(JNIEnv* env,
                                                                jobject,
                                                                jlong ptr,
                                                                jobject map) {
  auto* s = reinterpret_cast<Session*>(ptr);
  if (s && map) s->FillStats(env, map);
}

extern "C" JNIEXPORT void JNICALL
Java_com_livecatch_lixh_1player_LixhPlayerPlugin_nativeAttachSurface(JNIEnv* env,
                                                                    jobject,
                                                                    jlong ptr,
                                                                    jobject surface) {
  auto* s = reinterpret_cast<Session*>(ptr);
  if (s) s->AttachSurface(env, surface);
}

extern "C" JNIEXPORT void JNICALL
Java_com_livecatch_lixh_1player_LixhPlayerPlugin_nativeDetachSurface(JNIEnv*, jobject,
                                                                    jlong ptr) {
  auto* s = reinterpret_cast<Session*>(ptr);
  if (s) s->DetachSurface();
}
