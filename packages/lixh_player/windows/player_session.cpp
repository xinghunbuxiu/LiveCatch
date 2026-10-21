#include "player_session.h"

#include <d3d11.h>
#include <wrl/client.h>

#include <algorithm>
#include <cstdio>
#include <vector>

extern "C" {
#include "lixh_player.h"
#include <libavutil/frame.h>
#include <libavutil/pixfmt.h>
}

namespace lixh_player {
namespace {

inline uint8_t Clamp8(int v) {
  if (v < 0) return 0;
  if (v > 255) return 255;
  return static_cast<uint8_t>(v);
}

// BT.601 limited-range YUV to BGRA (software fallback path).
bool Yuv420ToBgra(const AVFrame* f, std::vector<uint8_t>* out) {
  const int w = f->width;
  const int h = f->height;
  if (!f->data[0] || w <= 0 || h <= 0) {
    return false;
  }
  const bool nv12 = f->format == AV_PIX_FMT_NV12 || f->format == AV_PIX_FMT_NV21;
  if (nv12) {
    if (!f->data[1]) return false;
  } else if (!f->data[1] || !f->data[2]) {
    return false;
  }
  out->assign(static_cast<size_t>(w) * static_cast<size_t>(h) * 4, 0);
  uint8_t* dst = out->data();
  for (int y = 0; y < h; ++y) {
    const uint8_t* yp = f->data[0] + y * f->linesize[0];
    const uint8_t* uv_row =
        nv12 ? (f->data[1] + (y / 2) * f->linesize[1]) : nullptr;
    const uint8_t* u_row =
        !nv12 ? (f->data[1] + (y / 2) * f->linesize[1]) : nullptr;
    const uint8_t* v_row =
        !nv12 ? (f->data[2] + (y / 2) * f->linesize[2]) : nullptr;
    uint8_t* row = dst + static_cast<size_t>(y) * static_cast<size_t>(w) * 4;
    for (int x = 0; x < w; ++x) {
      int Y = yp[x] - 16;
      int U, V;
      if (nv12) {
        const uint8_t* uv = uv_row + (x / 2) * 2;
        if (f->format == AV_PIX_FMT_NV21) {
          V = uv[0] - 128;
          U = uv[1] - 128;
        } else {
          U = uv[0] - 128;
          V = uv[1] - 128;
        }
      } else {
        U = u_row[x / 2] - 128;
        V = v_row[x / 2] - 128;
      }
      const int C = 298 * Y;
      const int r = (C + 409 * V + 128) >> 8;
      const int g = (C - 100 * U - 208 * V + 128) >> 8;
      const int b = (C + 516 * U + 128) >> 8;
      row[0] = Clamp8(b);
      row[1] = Clamp8(g);
      row[2] = Clamp8(r);
      row[3] = 255;
      row += 4;
    }
  }
  return true;
}

}  // namespace

PlayerSession::PlayerSession() = default;

PlayerSession::~PlayerSession() { Detach(); }

void PlayerSession::EnsurePresentThread() {
  if (present_running_.load()) {
    return;
  }
  present_running_.store(true);
  present_thread_ = std::thread([this]() { PresentLoop(); });
}

void PlayerSession::StopPresentThread() {
  if (!present_running_.exchange(false)) {
    if (present_thread_.joinable()) {
      present_thread_.join();
    }
    return;
  }
  present_cv_.notify_all();
  if (present_thread_.joinable()) {
    present_thread_.join();
  }
  present_pending_.store(false);
}

void PlayerSession::SignalPresent() {
  present_pending_.store(true);
  present_cv_.notify_one();
}

void PlayerSession::PresentLoop() {
  while (present_running_.load()) {
    {
      std::unique_lock<std::mutex> lock(present_mu_);
      present_cv_.wait(lock, [this]() {
        return !present_running_.load() || present_pending_.load();
      });
    }
    if (!present_running_.load()) {
      break;
    }
    present_pending_.store(false);

    SharedTextureBridge* bridge = nullptr;
    FrameReadyFn on_frame;
    {
      std::lock_guard<std::mutex> lock(mu_);
      bridge = bridge_;
      on_frame = on_frame_;
    }
    if (!bridge) {
      continue;
    }
    // Drain captures; demux may enqueue another while we publish.
    while (bridge->PublishCaptured()) {
      present_ok_.fetch_add(1);
      if (on_frame) {
        on_frame();
      }
    }
  }
}

bool PlayerSession::AttachTexture(SharedTextureBridge* bridge,
                                  FrameReadyFn on_frame) {
  {
    std::lock_guard<std::mutex> lock(mu_);
    bridge_ = bridge;
    on_frame_ = std::move(on_frame);
  }
  EnsurePresentThread();
  return bridge != nullptr;
}

bool PlayerSession::Open(const std::string& url, const std::string& headers) {
  Stop();
  LixhCallbacks cb = {};
  cb.opaque = this;
  cb.on_video = [](void* opaque, int kind, int width, int height,
                   int64_t /*pts_ms*/, int64_t /*duration_ms*/,
                   const LixhNativeFrame* frame) -> int {
    return static_cast<PlayerSession*>(opaque)->HandleVideo(
        kind, width, height, frame);
  };
  cb.on_event = [](void* opaque, int type, int code, const char* message) {
    OnEvent(opaque, type, code, message);
  };
  cb.on_audio = [](void* opaque, int sample_rate, int channels, int format,
                   int64_t pts_ms, const float* samples, int sample_count) {
    OnAudio(opaque, sample_rate, channels, format, pts_ms, samples,
            sample_count);
  };

  void* player = lixh_player_create(&cb);
  if (!player) {
    SetError("lixh_player_create failed");
    return false;
  }
  if (!headers.empty()) {
    lixh_player_set_headers(player, headers.c_str());
  }
  // Before open: listen-only skips video decoder/HW init.
  const bool picture = video_enabled_.load();
  lixh_player_set_video_sink(player, picture ? 1 : 0);
  const float open_rate =
      picture ? (std::min)(listen_play_rate_, 1.15f) : listen_play_rate_;
  lixh_player_set_play_rate(player, open_rate);
  lixh_player_set_latency(player, latency_target_ms_, latency_max_ms_);
  {
    const bool listen = !video_enabled_.load();
    int pcm_ms = listen ? (latency_target_ms_ + latency_target_ms_ / 2)
                        : (latency_target_ms_ * 2);
    const int floor = listen ? 60 : 100;
    if (pcm_ms < floor) pcm_ms = floor;
    if (pcm_ms > 400) pcm_ms = 400;
    audio_.SetMaxQueueMs(pcm_ms);
  }
  if (lixh_player_open(player, url.c_str()) < 0) {
    SetError("lixh_player_open failed");
    lixh_player_destroy(player);
    return false;
  }
  {
    std::lock_guard<std::mutex> lock(mu_);
    player_ = player;
  }
  return true;
}

bool PlayerSession::Play() {
  void* player = nullptr;
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
    player = player_;
    // Do NOT hold mu_ across lixh_player_play — on_video/HandleVideo needs it.
    play_thread_ = std::thread([this, player]() {
      const int rc = lixh_player_play(player);
      if (rc < 0) {
        SetError("lixh_player_play failed");
      }
    });
  }
  // Warm up WASAPI early so the first audio callback does not stall decode.
  if (!audio_.Start()) {
    const std::string err = audio_.last_error();
    SetError(err.empty() ? "audio start failed" : ("audio: " + err));
    // Video can still play; keep going.
  }
  return true;
}

void PlayerSession::Stop() {
  void* player = nullptr;
  std::thread to_join;
  {
    std::lock_guard<std::mutex> lock(mu_);
    player = player_;
    player_ = nullptr;
    if (play_thread_.joinable()) {
      to_join = std::move(play_thread_);
    }
  }
  if (player) {
    lixh_player_stop(player);
  }
  if (to_join.joinable()) {
    to_join.join();
  }
  if (player) {
    lixh_player_destroy(player);
  }
  audio_.Stop();
}

void PlayerSession::Detach() {
  Stop();
  StopPresentThread();
  std::lock_guard<std::mutex> lock(mu_);
  bridge_ = nullptr;
  on_frame_ = nullptr;
}

std::string PlayerSession::last_error() const {
  std::lock_guard<std::mutex> lock(mu_);
  return last_error_;
}

void PlayerSession::SetError(const std::string& msg) {
  std::lock_guard<std::mutex> lock(mu_);
  last_error_ = msg;
}

// static
void PlayerSession::OnEvent(void* opaque, int type, int /*code*/,
                            const char* message) {
  if (!opaque) {
    return;
  }
  if (type == LIXH_EVT_AUDIO_TIP_FLUSH) {
    static_cast<PlayerSession*>(opaque)->audio_.FlushTip();
    return;
  }
  if (!message) {
    return;
  }
  // INFO/STATE must not overwrite lastError — UI was showing "reconnecting" as failure.
  if (type != LIXH_EVT_ERROR) {
    return;
  }
  static_cast<PlayerSession*>(opaque)->SetError(message);
}

// static
void PlayerSession::OnAudio(void* opaque, int sample_rate, int channels,
                            int /*format*/, int64_t /*pts_ms*/,
                            const float* samples, int sample_count) {
  if (!opaque) {
    return;
  }
  static_cast<PlayerSession*>(opaque)->HandleAudio(sample_rate, channels,
                                                   samples, sample_count);
}

void PlayerSession::HandleAudio(int sample_rate, int channels,
                                const float* samples, int frames) {
  if (!samples || frames <= 0 || channels <= 0) {
    return;
  }
  // Ignore audio once Stop() has cleared the player (decode may race briefly).
  {
    std::lock_guard<std::mutex> lock(mu_);
    if (!player_) {
      return;
    }
  }
  audio_frames_.fetch_add(1);
  audio_.Push(samples, frames, channels, sample_rate);
}

void PlayerSession::SetLatency(int target_ms, int max_ms) {
  if (target_ms < 30) target_ms = 30;
  if (max_ms < target_ms) max_ms = target_ms;
  latency_target_ms_ = target_ms;
  latency_max_ms_ = max_ms;
  const bool listen = !video_enabled_.load();
  int pcm_ms = listen ? (target_ms + target_ms / 2) : (target_ms * 2);
  const int floor = listen ? 60 : 100;
  if (pcm_ms < floor) pcm_ms = floor;
  if (pcm_ms > 400) pcm_ms = 400;
  audio_.SetMaxQueueMs(pcm_ms);
  void* player = nullptr;
  {
    std::lock_guard<std::mutex> lock(mu_);
    player = player_;
  }
  if (player) {
    lixh_player_set_latency(player, latency_target_ms_, latency_max_ms_);
  }
}

void PlayerSession::SetVideoEnabled(bool enabled) {
  const bool was = video_enabled_.exchange(enabled);
  void* player = nullptr;
  {
    std::lock_guard<std::mutex> lock(mu_);
    player = player_;
    // Clear sticky errors so a prior capture glitch does not stay on the HUD.
    if (enabled) {
      last_error_.clear();
    }
  }
  std::fprintf(stderr, "[lixh] video_sink %d -> %d player=%p\n", was ? 1 : 0,
               enabled ? 1 : 0, player);
  std::fflush(stderr);
  if (player) {
    lixh_player_set_video_sink(player, enabled ? 1 : 0);
    const float rate =
        enabled ? (std::min)(listen_play_rate_, 1.15f) : listen_play_rate_;
    lixh_player_set_play_rate(player, rate);
  }
  // Re-lean PCM when returning to listen-only.
  SetLatency(latency_target_ms_, latency_max_ms_);
}

void PlayerSession::SetPlayRate(float rate) {
  if (rate < 1.f) rate = 1.f;
  if (rate > 1.5f) rate = 1.5f;
  listen_play_rate_ = rate;
  void* player = nullptr;
  {
    std::lock_guard<std::mutex> lock(mu_);
    player = player_;
  }
  if (player) {
    const bool picture = video_enabled_.load();
    const float applied =
        picture ? (std::min)(listen_play_rate_, 1.15f) : listen_play_rate_;
    lixh_player_set_play_rate(player, applied);
  }
}

PlayerSession::Stats PlayerSession::GetStats() const {
  Stats s;
  s.video_frames = video_frames_.load();
  s.present_ok = present_ok_.load();
  s.audio_frames = audio_frames_.load();
  s.decode_hw = decode_hw_.load();
  s.audio_queue_ms = audio_.queued_ms();
  // Hold mu_ across get_stats so Stop/destroy cannot free the player under us.
  {
    std::lock_guard<std::mutex> lock(mu_);
    s.last_error = last_error_;
    if (player_) {
      LixhStats core{};
      if (lixh_player_get_stats(player_, &core) == 0) {
        s.dropped_frames = core.dropped_frames;
        s.bytes_read = core.bytes_read;
        s.lag_ms = core.input_buffer_ms;
        s.video_width = core.video_width;
        s.video_height = core.video_height;
        if (s.decode_hw < 0 && core.decode_hw >= 0) {
          s.decode_hw = core.decode_hw;
        }
      }
    }
  }
  return s;
}

int PlayerSession::HandleVideo(int kind, int width, int height,
                               const void* frame_ptr) {
  const auto* frame = static_cast<const LixhNativeFrame*>(frame_ptr);
  if (!frame || !frame->handle0 || width <= 0 || height <= 0) {
    // Skip frame — never return -1 here (that forces demux-thread CPU download).
    return 1;
  }
  video_frames_.fetch_add(1);
  // 1 = skip present AND expensive hwframe_transfer (see lixh_player.c).
  if (!video_enabled_.load()) {
    return 1;
  }
  SharedTextureBridge* bridge = nullptr;
  {
    std::lock_guard<std::mutex> lock(mu_);
    bridge = bridge_;
  }
  if (!bridge) {
    return 1;
  }
  EnsurePresentThread();

  // Cap capture enqueue ~45fps — demux never waits on VP/Flush.
  static LARGE_INTEGER freq = {};
  static LONGLONG last_capture_qpc = 0;
  if (freq.QuadPart == 0) {
    QueryPerformanceFrequency(&freq);
  }
  LARGE_INTEGER now_qpc;
  QueryPerformanceCounter(&now_qpc);
  if (last_capture_qpc != 0 && freq.QuadPart > 0) {
    const double ms = (now_qpc.QuadPart - last_capture_qpc) * 1000.0 /
                      static_cast<double>(freq.QuadPart);
    if (ms < 15.0) {
      return 1;
    }
  }

  bool ok = false;
  if (kind == LIXH_VIDEO_D3D11) {
    decode_hw_.store(1);
    auto* tex = static_cast<ID3D11Texture2D*>(frame->handle0);
    Microsoft::WRL::ComPtr<ID3D11Device> src_device;
    tex->GetDevice(&src_device);
    if (!bridge->ready() || bridge->device() != src_device.Get() ||
        bridge->width() != static_cast<uint32_t>(width) ||
        bridge->height() != static_cast<uint32_t>(height)) {
      if (!bridge->InitializeWithDevice(src_device.Get(),
                                        static_cast<uint32_t>(width),
                                        static_cast<uint32_t>(height))) {
        // Customer GPUs sometimes fail shared-HANDLE create transiently.
        // Skip this frame and keep trying direct D3D11 — do NOT force SW path.
        static int init_fail_logs = 0;
        if (init_fail_logs < 8) {
          ++init_fail_logs;
          std::fprintf(stderr, "[lixh] InitializeWithDevice fail %dx%d\n",
                       width, height);
          std::fflush(stderr);
        }
        return 1;
      }
    }
    const UINT sub = frame->handle1 > 0 ? static_cast<UINT>(frame->handle1) : 0;
    ok = bridge->CaptureFromTexture(tex, sub);
  } else if (kind == LIXH_VIDEO_SOFTWARE) {
    decode_hw_.store(0);
    const auto* av = static_cast<const AVFrame*>(frame->handle0);
    if (!av || !av->data[0]) {
      return 1;
    }
    if (av->format != AV_PIX_FMT_YUV420P && av->format != AV_PIX_FMT_YUVJ420P &&
        av->format != AV_PIX_FMT_NV12 && av->format != AV_PIX_FMT_NV21) {
      return 1;
    }
    thread_local std::vector<uint8_t> bgra;
    if (!Yuv420ToBgra(av, &bgra)) {
      return 1;
    }
    ok = bridge->CaptureBgra(bgra.data(), static_cast<uint32_t>(av->width),
                             static_cast<uint32_t>(av->height),
                             static_cast<uint32_t>(av->width) * 4);
  } else {
    return 1;
  }

  if (!ok) {
    static int present_fail_logs = 0;
    if (present_fail_logs < 8) {
      ++present_fail_logs;
      std::fprintf(stderr, "[lixh] capture FAIL kind=%d %dx%d\n", kind, width,
                   height);
      std::fflush(stderr);
    }
    // Skip only — returning -1 used to permanently enable demux-thread
    // av_hwframe_transfer_data and stall live reads on weak GPUs.
    return 1;
  }
  QueryPerformanceCounter(&now_qpc);
  last_capture_qpc = now_qpc.QuadPart;
  SignalPresent();
  return 0;
}

}  // namespace lixh_player
