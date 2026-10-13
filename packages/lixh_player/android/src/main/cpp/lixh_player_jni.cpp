#include <android/api-level.h>
#include <android/log.h>
#include <android/native_window.h>
#include <android/native_window_jni.h>
#include <dlfcn.h>
#include <jni.h>
#include <SLES/OpenSLES.h>
#include <SLES/OpenSLES_Android.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstring>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

/* AAudio types — avoid linking libaaudio (missing on API 24–25). */
using aaudio_result_t = int32_t;
using aaudio_sharing_mode_t = int32_t;
using aaudio_direction_t = int32_t;
using aaudio_format_t = int32_t;
using aaudio_performance_mode_t = int32_t;
using aaudio_data_callback_result_t = int32_t;
using aaudio_usage_t = int32_t;
using aaudio_content_type_t = int32_t;
struct AAudioStreamStruct;
struct AAudioStreamBuilderStruct;
using AAudioStream = AAudioStreamStruct;
using AAudioStreamBuilder = AAudioStreamBuilderStruct;
using AAudioStream_dataCallback = aaudio_data_callback_result_t (*)(
    AAudioStream* stream, void* userData, void* audioData, int32_t numFrames);

constexpr aaudio_result_t kAAudioOk = 0;
constexpr aaudio_direction_t kAAudioOutput = 0;
constexpr aaudio_sharing_mode_t kAAudioShared = 1;
constexpr aaudio_format_t kAAudioPcmFloat = 2;
constexpr aaudio_performance_mode_t kAAudioPerfNone = 10;
constexpr aaudio_performance_mode_t kAAudioPerfLowLatency = 12;
constexpr aaudio_data_callback_result_t kAAudioContinue = 0;
constexpr aaudio_usage_t kAAudioUsageMedia = 1;
constexpr aaudio_content_type_t kAAudioContentMusic = 2;

struct AAudioApi {
  void* lib = nullptr;
  aaudio_result_t (*createStreamBuilder)(AAudioStreamBuilder** builder) = nullptr;
  void (*builder_setDirection)(AAudioStreamBuilder*, aaudio_direction_t) = nullptr;
  void (*builder_setSharingMode)(AAudioStreamBuilder*, aaudio_sharing_mode_t) = nullptr;
  void (*builder_setFormat)(AAudioStreamBuilder*, aaudio_format_t) = nullptr;
  void (*builder_setChannelCount)(AAudioStreamBuilder*, int32_t) = nullptr;
  void (*builder_setSampleRate)(AAudioStreamBuilder*, int32_t) = nullptr;
  void (*builder_setPerformanceMode)(AAudioStreamBuilder*,
                                     aaudio_performance_mode_t) = nullptr;
  void (*builder_setDataCallback)(AAudioStreamBuilder*, AAudioStream_dataCallback,
                                  void*) = nullptr;
  void (*builder_setFramesPerDataCallback)(AAudioStreamBuilder*, int32_t) = nullptr;
  void (*builder_setUsage)(AAudioStreamBuilder*, aaudio_usage_t) = nullptr;
  void (*builder_setContentType)(AAudioStreamBuilder*, aaudio_content_type_t) = nullptr;
  aaudio_result_t (*builder_openStream)(AAudioStreamBuilder*, AAudioStream**) = nullptr;
  void (*builder_delete)(AAudioStreamBuilder*) = nullptr;
  int32_t (*stream_getFramesPerBurst)(AAudioStream*) = nullptr;
  aaudio_result_t (*stream_setBufferSizeInFrames)(AAudioStream*, int32_t) = nullptr;
  aaudio_result_t (*stream_requestStart)(AAudioStream*) = nullptr;
  aaudio_result_t (*stream_requestStop)(AAudioStream*) = nullptr;
  aaudio_result_t (*stream_close)(AAudioStream*) = nullptr;

  bool Load() {
    if (lib) return createStreamBuilder != nullptr;
    lib = dlopen("libaaudio.so", RTLD_NOW);
    if (!lib) return false;
#define LIXH_AA_LOAD(name, field) \
  field = reinterpret_cast<decltype(field)>(dlsym(lib, name))
    LIXH_AA_LOAD("AAudio_createStreamBuilder", createStreamBuilder);
    LIXH_AA_LOAD("AAudioStreamBuilder_setDirection", builder_setDirection);
    LIXH_AA_LOAD("AAudioStreamBuilder_setSharingMode", builder_setSharingMode);
    LIXH_AA_LOAD("AAudioStreamBuilder_setFormat", builder_setFormat);
    LIXH_AA_LOAD("AAudioStreamBuilder_setChannelCount", builder_setChannelCount);
    LIXH_AA_LOAD("AAudioStreamBuilder_setSampleRate", builder_setSampleRate);
    LIXH_AA_LOAD("AAudioStreamBuilder_setPerformanceMode", builder_setPerformanceMode);
    LIXH_AA_LOAD("AAudioStreamBuilder_setDataCallback", builder_setDataCallback);
    LIXH_AA_LOAD("AAudioStreamBuilder_setFramesPerDataCallback",
                 builder_setFramesPerDataCallback);
    LIXH_AA_LOAD("AAudioStreamBuilder_setUsage", builder_setUsage);
    LIXH_AA_LOAD("AAudioStreamBuilder_setContentType", builder_setContentType);
    LIXH_AA_LOAD("AAudioStreamBuilder_openStream", builder_openStream);
    LIXH_AA_LOAD("AAudioStreamBuilder_delete", builder_delete);
    LIXH_AA_LOAD("AAudioStream_getFramesPerBurst", stream_getFramesPerBurst);
    LIXH_AA_LOAD("AAudioStream_setBufferSizeInFrames", stream_setBufferSizeInFrames);
    LIXH_AA_LOAD("AAudioStream_requestStart", stream_requestStart);
    LIXH_AA_LOAD("AAudioStream_requestStop", stream_requestStop);
    LIXH_AA_LOAD("AAudioStream_close", stream_close);
#undef LIXH_AA_LOAD
    return createStreamBuilder && builder_openStream && stream_requestStart &&
           stream_close;
  }
};

static AAudioApi& AAudioFns() {
  static AAudioApi api;
  return api;
}

extern "C" {
#include "lixh_player.h"
#include <libavutil/frame.h>
#include <libavutil/imgutils.h>
#include <libswscale/swscale.h>
}

#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, "lixh", __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, "lixh", __VA_ARGS__)

namespace {

/* ~500ms stereo @48k — physical ceiling; live trim keeps far less. */
constexpr int kRingCap = 48000 * 2 / 2;

/* Video chase target ≠ safe PCM depth. Listen needs enough to prime the
   sink (too-tight snap never primes → permanent silence until picture
   fattens the queue once). Picture keeps a fatter cushion. */
static int PcmQueueMsFromChase(int chase_target_ms, bool listen_only) {
  int pcm = listen_only ? (chase_target_ms + chase_target_ms / 2)
                        : (chase_target_ms * 2);
  /* Listen 60ms matches Windows snap floor; picture stays ≥100ms. */
  const int floor = listen_only ? 60 : 100;
  if (pcm < floor) pcm = floor;
  if (pcm > 400) pcm = 400;
  return pcm;
}

class AudioOut {
 public:
  ~AudioOut() { Stop(); }

  void SetMaxQueueMs(int ms) {
    std::lock_guard<std::mutex> lock(mu_);
    if (ms < 50) ms = 50;
    if (ms > 400) ms = 400;
    base_queue_ms_ = ms;
    max_queue_ms_ = ms;
    last_underrun_ = {};
    last_shrink_ = {};
  }

  /* Prime below the queue cap so we always become audible. Equal prime==cap
     + trim-while-unprimed caused permanent silence on listen-first. */
  int PrimeNeedMsLocked() const {
    int p = base_queue_ms_ * 2 / 3;
    if (p < 20) p = 20;
    if (p > 120) p = 120;
    if (p >= base_queue_ms_) p = base_queue_ms_ > 20 ? base_queue_ms_ - 10 : 20;
    return p;
  }

  void NoteUnderrunLocked() {
    last_underrun_ = std::chrono::steady_clock::now();
    if (max_queue_ms_ < 280) {
      int next = max_queue_ms_ + 40;
      if (next > 280) next = 280;
      if (next < base_queue_ms_) next = base_queue_ms_;
      max_queue_ms_ = next;
    }
  }

  /* After ~3s without underrun, ease depth back toward base (20ms/s). */
  void MaybeShrinkLocked() {
    if (max_queue_ms_ <= base_queue_ms_ || !primed_) return;
    const auto now = std::chrono::steady_clock::now();
    if (last_underrun_.time_since_epoch().count() != 0 &&
        now - last_underrun_ < std::chrono::seconds(3)) {
      return;
    }
    if (last_shrink_.time_since_epoch().count() != 0 &&
        now - last_shrink_ < std::chrono::milliseconds(1000)) {
      return;
    }
    /* Only shrink when we still have a small cushion — empty ring is risky. */
    int qms = (rate_ > 0 && ch_ > 0) ? (int)((count_ / ch_) * 1000L / rate_) : 0;
    if (qms < 25) return;
    last_shrink_ = now;
    int next = max_queue_ms_ - 20;
    if (next < base_queue_ms_) next = base_queue_ms_;
    max_queue_ms_ = next;
  }

  void Push(const float* samples, int frames, int channels, int rate) {
    if (!samples || frames <= 0 || channels <= 0) return;
    std::lock_guard<std::mutex> lock(mu_);
    if (!Ensure(rate, channels)) return;
    int n = frames * channels;
    if (n > kRingCap / 2) n = kRingCap / 2;
    int cap_ms = max_queue_ms_;
    if (!primed_) {
      int p = PrimeNeedMsLocked();
      if (cap_ms < p + 30) cap_ms = p + 30;
    }
    int max_samples = ch_ * rate_ * cap_ms / 1000;
    /* Soft floor for trim safety — never force above the active cap. */
    int floor_ms = max_queue_ms_ < 100 ? 50 : (max_queue_ms_ < 140 ? 80 : 100);
    if (floor_ms > max_queue_ms_) floor_ms = max_queue_ms_;
    if (max_samples < ch_ * rate_ * floor_ms / 1000) {
      max_samples = ch_ * rate_ * floor_ms / 1000;
    }
    if (max_samples > kRingCap - n) max_samples = kRingCap - n;
    const bool snap = max_queue_ms_ <= 80;
    const int trim_at = snap ? max_samples : (max_samples + max_samples / 4);
    const int keep_ms =
        max_queue_ms_ >= 160 ? 80 : (max_queue_ms_ >= 100 ? 50 : 40);
    /* Never trim below prime threshold while still silent. */
    const int prime_keep = ch_ * rate_ * PrimeNeedMsLocked() / 1000;
    const int min_keep =
        primed_ ? (ch_ * rate_ * keep_ms / 1000) : prime_keep;
    while (count_ + n > trim_at && count_ > min_keep) {
      int drop = ch_ * (snap ? (rate_ / 25) : (rate_ / 50));  // ~40ms / ~20ms
      if (drop < 1) drop = n;
      if (drop > count_ - min_keep) drop = count_ - min_keep;
      if (drop < 1) break;
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
    if (primed_) MaybeShrinkLocked();
  }

  void Stop() {
    std::lock_guard<std::mutex> lock(mu_);
    StopLocked();
  }

  int QueuedMs() const {
    std::lock_guard<std::mutex> lock(mu_);
    if (rate_ <= 0 || ch_ <= 0) return 0;
    return (int)((count_ / ch_) * 1000L / rate_);
  }

 private:
  enum class Backend { None, AAudio, OpenSL };

  void StopLocked() {
    if (aaudio_stream_) {
      auto& a = AAudioFns();
      if (a.stream_requestStop) a.stream_requestStop(aaudio_stream_);
      if (a.stream_close) a.stream_close(aaudio_stream_);
      aaudio_stream_ = nullptr;
    }
    DestroyOpenSLLocked();
    backend_ = Backend::None;
    r_ = w_ = count_ = 0;
    primed_ = false;
  }

  static aaudio_data_callback_result_t AAudioCallback(AAudioStream* /*s*/,
                                                      void* user, void* audio,
                                                      int32_t num_frames) {
    auto* self = static_cast<AudioOut*>(user);
    return self->OnAAudio(static_cast<float*>(audio), num_frames);
  }

  /* Shared ring drain for AAudio (float) and OpenSL (s16). */
  bool DrainRingLocked(float* dst_f, int16_t* dst_s16, int need_samples) {
    if (!primed_) {
      int qms = (rate_ > 0 && ch_ > 0) ? (int)((count_ / ch_) * 1000L / rate_) : 0;
      if (qms >= PrimeNeedMsLocked()) {
        primed_ = true;
      } else {
        if (dst_f) memset(dst_f, 0, (size_t)need_samples * sizeof(float));
        if (dst_s16) memset(dst_s16, 0, (size_t)need_samples * sizeof(int16_t));
        return true;
      }
    }
    int got = 0;
    while (got < need_samples && count_ > 0) {
      int n = need_samples - got;
      if (n > count_) n = count_;
      int to_end = kRingCap - r_;
      if (n > to_end) n = to_end;
      if (dst_f) {
        memcpy(dst_f + got, ring_.data() + r_, (size_t)n * sizeof(float));
      }
      if (dst_s16) {
        for (int i = 0; i < n; ++i) {
          float s = ring_[r_ + i];
          if (s > 1.f) s = 1.f;
          if (s < -1.f) s = -1.f;
          dst_s16[got + i] = (int16_t)(s * 32767.f);
        }
      }
      r_ = (r_ + n) % kRingCap;
      count_ -= n;
      got += n;
    }
    if (got < need_samples) {
      if (dst_f) {
        memset(dst_f + got, 0, (size_t)(need_samples - got) * sizeof(float));
      }
      if (dst_s16) {
        memset(dst_s16 + got, 0, (size_t)(need_samples - got) * sizeof(int16_t));
      }
      NoteUnderrunLocked();
    } else {
      MaybeShrinkLocked();
    }
    return true;
  }

  aaudio_data_callback_result_t OnAAudio(float* dst, int32_t num_frames) {
    int need = num_frames * ch_;
    /* try_lock: must not block — Push may hold mu_ while opening the stream. */
    std::unique_lock<std::mutex> lock(mu_, std::try_to_lock);
    if (!lock.owns_lock()) {
      memset(dst, 0, (size_t)need * sizeof(float));
      return kAAudioContinue;
    }
    DrainRingLocked(dst, nullptr, need);
    return kAAudioContinue;
  }

  static void OpenSLCallback(SLAndroidSimpleBufferQueueItf bq, void* ctx) {
    auto* self = static_cast<AudioOut*>(ctx);
    self->OnOpenSL(bq);
  }

  void OnOpenSL(SLAndroidSimpleBufferQueueItf bq) {
    const int frames = rate_ / 100; /* ~10ms */
    const int need = frames * ch_;
    if ((int)sl_buf_.size() < need) sl_buf_.assign(need, 0);
    {
      std::unique_lock<std::mutex> lock(mu_, std::try_to_lock);
      if (!lock.owns_lock()) {
        memset(sl_buf_.data(), 0, (size_t)need * sizeof(int16_t));
      } else {
        DrainRingLocked(nullptr, sl_buf_.data(), need);
      }
    }
    (*bq)->Enqueue(bq, sl_buf_.data(), (SLuint32)(need * sizeof(int16_t)));
  }

  void DestroyOpenSLLocked() {
    if (sl_player_obj_) {
      (*sl_player_obj_)->Destroy(sl_player_obj_);
      sl_player_obj_ = nullptr;
      sl_play_ = nullptr;
      sl_bq_ = nullptr;
    }
    if (sl_mix_obj_) {
      (*sl_mix_obj_)->Destroy(sl_mix_obj_);
      sl_mix_obj_ = nullptr;
    }
    if (sl_engine_obj_) {
      (*sl_engine_obj_)->Destroy(sl_engine_obj_);
      sl_engine_obj_ = nullptr;
      sl_engine_ = nullptr;
    }
    sl_buf_.clear();
  }

  bool OpenOpenSLLocked() {
    DestroyOpenSLLocked();
    if (slCreateEngine(&sl_engine_obj_, 0, nullptr, 0, nullptr, nullptr) !=
        SL_RESULT_SUCCESS) {
      return false;
    }
    (*sl_engine_obj_)->Realize(sl_engine_obj_, SL_BOOLEAN_FALSE);
    (*sl_engine_obj_)
        ->GetInterface(sl_engine_obj_, SL_IID_ENGINE, &sl_engine_);
    if (!sl_engine_) return false;

    const SLInterfaceID mix_ids[] = {SL_IID_VOLUME};
    const SLboolean mix_req[] = {SL_BOOLEAN_FALSE};
    (*sl_engine_)
        ->CreateOutputMix(sl_engine_, &sl_mix_obj_, 1, mix_ids, mix_req);
    (*sl_mix_obj_)->Realize(sl_mix_obj_, SL_BOOLEAN_FALSE);

    SLDataLocator_AndroidSimpleBufferQueue loc_bq = {
        SL_DATALOCATOR_ANDROIDSIMPLEBUFFERQUEUE, 2};
    SLDataFormat_PCM fmt = {
        SL_DATAFORMAT_PCM,
        (SLuint32)ch_,
        (SLuint32)(rate_ * 1000),
        SL_PCMSAMPLEFORMAT_FIXED_16,
        SL_PCMSAMPLEFORMAT_FIXED_16,
        ch_ == 1 ? SL_SPEAKER_FRONT_CENTER
                 : (SL_SPEAKER_FRONT_LEFT | SL_SPEAKER_FRONT_RIGHT),
        SL_BYTEORDER_LITTLEENDIAN};
    SLDataSource src = {&loc_bq, &fmt};
    SLDataLocator_OutputMix loc_out = {SL_DATALOCATOR_OUTPUTMIX, sl_mix_obj_};
    SLDataSink sink = {&loc_out, nullptr};
    const SLInterfaceID ids[] = {SL_IID_ANDROIDSIMPLEBUFFERQUEUE, SL_IID_VOLUME};
    const SLboolean req[] = {SL_BOOLEAN_TRUE, SL_BOOLEAN_FALSE};
    if ((*sl_engine_)
            ->CreateAudioPlayer(sl_engine_, &sl_player_obj_, &src, &sink, 2, ids,
                                req) != SL_RESULT_SUCCESS) {
      DestroyOpenSLLocked();
      return false;
    }
    (*sl_player_obj_)->Realize(sl_player_obj_, SL_BOOLEAN_FALSE);
    (*sl_player_obj_)->GetInterface(sl_player_obj_, SL_IID_PLAY, &sl_play_);
    (*sl_player_obj_)
        ->GetInterface(sl_player_obj_, SL_IID_ANDROIDSIMPLEBUFFERQUEUE, &sl_bq_);
    if (!sl_play_ || !sl_bq_) {
      DestroyOpenSLLocked();
      return false;
    }
    (*sl_bq_)->RegisterCallback(sl_bq_, OpenSLCallback, this);
    const int frames = rate_ / 100;
    const int need = frames * ch_;
    sl_buf_.assign(need, 0);
    (*sl_bq_)->Enqueue(sl_bq_, sl_buf_.data(), (SLuint32)(need * sizeof(int16_t)));
    (*sl_bq_)->Enqueue(sl_bq_, sl_buf_.data(), (SLuint32)(need * sizeof(int16_t)));
    (*sl_play_)->SetPlayState(sl_play_, SL_PLAYSTATE_PLAYING);
    backend_ = Backend::OpenSL;
    LOGI("audio backend=OpenSL rate=%d ch=%d", rate_, ch_);
    return true;
  }

  bool OpenAAudioLocked() {
    auto& a = AAudioFns();
    if (!a.Load()) return false;
    /* Shared mixer: STREAM_MUSIC volume applies. Prefer LowLatency; fall back
       to None on OEMs that reject it. Never Exclusive (Pixel volume pitfall). */
    auto try_open = [&](aaudio_performance_mode_t perf) -> AAudioStream* {
      AAudioStreamBuilder* bb = nullptr;
      if (a.createStreamBuilder(&bb) != kAAudioOk || !bb) return nullptr;
      a.builder_setDirection(bb, kAAudioOutput);
      a.builder_setSharingMode(bb, kAAudioShared);
      a.builder_setFormat(bb, kAAudioPcmFloat);
      a.builder_setChannelCount(bb, ch_);
      a.builder_setSampleRate(bb, rate_);
      if (a.builder_setUsage) a.builder_setUsage(bb, kAAudioUsageMedia);
      if (a.builder_setContentType) {
        a.builder_setContentType(bb, kAAudioContentMusic);
      }
      if (a.builder_setPerformanceMode) a.builder_setPerformanceMode(bb, perf);
      a.builder_setDataCallback(bb, AAudioCallback, this);
      a.builder_setFramesPerDataCallback(bb, rate_ / 100);
      AAudioStream* s = nullptr;
      aaudio_result_t r = a.builder_openStream(bb, &s);
      a.builder_delete(bb);
      if (r != kAAudioOk || !s) return nullptr;
      return s;
    };
    AAudioStream* stream = try_open(kAAudioPerfLowLatency);
    bool low_lat = stream != nullptr;
    if (!stream) stream = try_open(kAAudioPerfNone);
    if (!stream) return false;
    int32_t burst =
        a.stream_getFramesPerBurst ? a.stream_getFramesPerBurst(stream) : 0;
    if (burst > 0 && a.stream_setBufferSizeInFrames) {
      /* 3 bursts: leaner than 4; still above exclusive MMAP crackle zone. */
      a.stream_setBufferSizeInFrames(stream, burst * 3);
    }
    if (a.stream_requestStart(stream) != kAAudioOk) {
      a.stream_close(stream);
      return false;
    }
    aaudio_stream_ = stream;
    backend_ = Backend::AAudio;
    LOGI("audio backend=AAudio share=shared perf=%s rate=%d ch=%d usage=%s",
         low_lat ? "lowlat" : "none", rate_, ch_,
         a.builder_setUsage ? "media" : "default");
    return true;
  }

  bool Ensure(int rate, int ch) {
    if (backend_ != Backend::None && rate_ == rate && ch_ == ch) return true;
    StopLocked();
    rate_ = rate > 0 ? rate : 48000;
    ch_ = ch > 0 ? ch : 2;
    ring_.assign(kRingCap, 0.f);
    r_ = w_ = count_ = 0;
    primed_ = false;

    const int api = android_get_device_api_level();
    if (api >= 26 && AAudioFns().Load()) {
      if (OpenAAudioLocked()) return true;
      LOGE("AAudio open failed on API %d — falling back to OpenSL", api);
    }
    return OpenOpenSLLocked();
  }

  mutable std::mutex mu_;
  std::vector<float> ring_ = std::vector<float>(kRingCap);
  int r_ = 0, w_ = 0, count_ = 0, rate_ = 48000, ch_ = 2;
  int base_queue_ms_ = 120;
  int max_queue_ms_ = 120;
  bool primed_ = false;
  std::chrono::steady_clock::time_point last_underrun_{};
  std::chrono::steady_clock::time_point last_shrink_{};
  Backend backend_ = Backend::None;
  AAudioStream* aaudio_stream_ = nullptr;

  SLObjectItf sl_engine_obj_ = nullptr;
  SLEngineItf sl_engine_ = nullptr;
  SLObjectItf sl_mix_obj_ = nullptr;
  SLObjectItf sl_player_obj_ = nullptr;
  SLPlayItf sl_play_ = nullptr;
  SLAndroidSimpleBufferQueueItf sl_bq_ = nullptr;
  std::vector<int16_t> sl_buf_;
};

class Session {
 public:
  Session() = default;
  ~Session() {
    Stop();
    /* Best-effort: Detach without JNIEnv leaves GlobalRef until process exit
       if destroy skipped Attach/Detach — plugin always Detach before Destroy. */
    ClearWindowLocked();
  }

  void AttachSurface(JNIEnv* env, jobject surface) {
    jobject global = nullptr;
    ANativeWindow* win = nullptr;
    {
      std::lock_guard<std::mutex> lock(win_mu_);
      ClearSurfaceRefs(env);
      if (surface) {
        surface_global_ = env->NewGlobalRef(surface);
        window_ = ANativeWindow_fromSurface(env, surface);
      }
      global = surface_global_;
      win = window_;
      last_present_ = {};
    }
    void* p = nullptr;
    {
      std::lock_guard<std::mutex> plock(mu_);
      p = player_;
    }
    if (p) lixh_player_set_android_surface(p, global);
    LOGI("attach surface global=%p window=%p", global, win);
  }

  void DetachSurface(JNIEnv* env) {
    void* p = nullptr;
    {
      std::lock_guard<std::mutex> plock(mu_);
      p = player_;
    }
    if (p) lixh_player_set_android_surface(p, nullptr);
    std::lock_guard<std::mutex> lock(win_mu_);
    ClearSurfaceRefs(env);
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
    {
      std::lock_guard<std::mutex> lock(win_mu_);
      lixh_player_set_android_surface(p, surface_global_);
    }
    // Before open: listen-only skips video decoder (AVDISCARD) + catch-up rate.
    // Picture still keeps a mild ceiling so lag can clear without 1.0x forever.
    const bool picture = video_enabled_.load();
    lixh_player_set_video_sink(p, picture ? 1 : 0);
    const float rate =
        picture ? std::min(listen_play_rate_, 1.15f) : listen_play_rate_;
    lixh_player_set_play_rate(p, rate);
    lixh_player_set_latency(p, latency_target_ms_, latency_max_ms_);
    if (lixh_player_open(p, url.c_str()) < 0) {
      SetError("lixh_player_open failed");
      lixh_player_destroy(p);
      return false;
    }
    audio_.SetMaxQueueMs(
        PcmQueueMsFromChase((int)latency_target_ms_, !video_enabled_.load()));
    std::lock_guard<std::mutex> lock(mu_);
    player_ = p;
    LOGI("open url=%zu surface=%p", url.size(), surface_global_);
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
      if (on) last_error_.clear();
    }
    if (p) {
      lixh_player_set_video_sink(p, on ? 1 : 0);
      const float rate =
          on ? std::min(listen_play_rate_, 1.15f) : listen_play_rate_;
      lixh_player_set_play_rate(p, rate);
    }
    /* Re-lean PCM when returning to listen-only. */
    audio_.SetMaxQueueMs(
        PcmQueueMsFromChase((int)latency_target_ms_, !on));
  }

  void SetPlayRate(float rate) {
    if (rate < 1.f) rate = 1.f;
    if (rate > 1.5f) rate = 1.5f;
    listen_play_rate_ = rate;
    void* p = nullptr;
    {
      std::lock_guard<std::mutex> lock(mu_);
      p = player_;
    }
    if (p) {
      const bool picture = video_enabled_.load();
      const float applied =
          picture ? std::min(listen_play_rate_, 1.15f) : listen_play_rate_;
      lixh_player_set_play_rate(p, applied);
    }
  }

  void SetLatency(int target_ms, int max_ms) {
    if (target_ms < 30) target_ms = 30;
    if (max_ms < target_ms) max_ms = target_ms;
    latency_target_ms_ = target_ms;
    latency_max_ms_ = max_ms;
    audio_.SetMaxQueueMs(
        PcmQueueMsFromChase(target_ms, !video_enabled_.load()));
    void* p = nullptr;
    {
      std::lock_guard<std::mutex> lock(mu_);
      p = player_;
    }
    if (p) lixh_player_set_latency(p, latency_target_ms_, latency_max_ms_);
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
    int vw = 0, vh = 0, decode_hw = 0, present_mode = 0;
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
          present_mode = core.present_mode;
        }
      }
    }
    putI("decodeHw", decode_hw);
    putI("presentMode", present_mode);
    putL("droppedFrames", (int64_t)dropped);
    putL("bytesRead", (int64_t)bread);
    putL("lagMs", lag);
    putI("videoWidth", vw);
    putI("videoHeight", vh);
    putS("lastError", err);
  }

 private:
  void ClearWindowLocked() {
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

  void ClearSurfaceRefs(JNIEnv* env) {
    ClearWindowLocked();
    if (surface_global_ && env) {
      env->DeleteGlobalRef(surface_global_);
    }
    surface_global_ = nullptr;
  }

  int OnVideo(int kind, int width, int height, const LixhNativeFrame* frame) {
    video_frames_.fetch_add(1);
    if (!video_enabled_.load()) return 1;

    /* MediaCodec Surface path: core releases with render=1 when we return 0. */
    if (kind == LIXH_VIDEO_MEDIACODEC) {
      present_ok_.fetch_add(1);
      return 0;
    }

    if (kind != LIXH_VIDEO_SOFTWARE || !frame || !frame->handle0) return 1;
    if (width <= 0 || height <= 0) return 1;

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
      // Skip frame only — never -1 (avoids treating present glitches as fatal).
      return 1;
    }

    int ok = 1;
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
  jobject surface_global_ = nullptr;
  SwsContext* sws_ = nullptr;
  int sws_w_ = 0, sws_h_ = 0, sws_fmt_ = AV_PIX_FMT_NONE;
  std::chrono::steady_clock::time_point last_present_{};
  std::string last_error_;
  std::atomic<uint64_t> video_frames_{0};
  std::atomic<uint64_t> audio_frames_{0};
  std::atomic<uint64_t> present_ok_{0};
  std::atomic<bool> video_enabled_{false};
  float listen_play_rate_ = 1.3f;
  int latency_target_ms_ = 40;
  int latency_max_ms_ = 160;
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

extern "C" JNIEXPORT void JNICALL
Java_com_livecatch_lixh_1player_LixhPlayerPlugin_nativeSetLatency(JNIEnv*, jobject,
                                                                  jlong ptr,
                                                                  jint targetMs,
                                                                  jint maxMs) {
  auto* s = reinterpret_cast<Session*>(ptr);
  if (s) s->SetLatency((int)targetMs, (int)maxMs);
}

extern "C" JNIEXPORT void JNICALL
Java_com_livecatch_lixh_1player_LixhPlayerPlugin_nativeSetPlayRate(JNIEnv*, jobject,
                                                                   jlong ptr,
                                                                   jfloat rate) {
  auto* s = reinterpret_cast<Session*>(ptr);
  if (s) s->SetPlayRate((float)rate);
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
Java_com_livecatch_lixh_1player_LixhPlayerPlugin_nativeDetachSurface(JNIEnv* env, jobject,
                                                                    jlong ptr) {
  auto* s = reinterpret_cast<Session*>(ptr);
  if (s) s->DetachSurface(env);
}
