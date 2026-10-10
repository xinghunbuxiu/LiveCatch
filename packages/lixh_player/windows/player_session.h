#ifndef LIXH_PLAYER_PLAYER_SESSION_H_
#define LIXH_PLAYER_PLAYER_SESSION_H_

#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <functional>
#include <mutex>
#include <string>
#include <thread>

#include "audio_output.h"
#include "shared_texture.h"

namespace lixh_player {

// Owns a lixh_player_core instance and feeds SharedTextureBridge from
// on_video callbacks (D3D11 GPU copy or software BGRA upload).
// lixh_player_play() is blocking — always run it on play_thread_.
// Present (VP + Flush + Flutter notify) runs on present_thread_ so demux
// only does a fast CaptureFromTexture / CaptureBgra.
class PlayerSession {
 public:
  using FrameReadyFn = std::function<void()>;

  PlayerSession();
  ~PlayerSession();

  PlayerSession(const PlayerSession&) = delete;
  PlayerSession& operator=(const PlayerSession&) = delete;

  bool AttachTexture(SharedTextureBridge* bridge, FrameReadyFn on_frame);
  bool Open(const std::string& url, const std::string& headers = {});
  bool Play();
  void Stop();
  void Detach();
  void SetVideoEnabled(bool enabled);
  bool video_enabled() const { return video_enabled_.load(); }

  struct Stats {
    uint64_t video_frames = 0;
    uint64_t present_ok = 0;
    uint64_t audio_frames = 0;
    uint64_t dropped_frames = 0;
    uint64_t bytes_read = 0;
    int64_t lag_ms = 0;
    int audio_queue_ms = 0;
    int decode_hw = -1;
    int video_width = 0;
    int video_height = 0;
    std::string last_error;
  };

  Stats GetStats() const;
  uint64_t video_frames() const { return video_frames_.load(); }
  uint64_t present_ok() const { return present_ok_.load(); }
  uint64_t audio_frames() const { return audio_frames_.load(); }
  int decode_hw() const { return decode_hw_.load(); }
  std::string last_error() const;

 private:
  static void OnEvent(void* opaque, int type, int code, const char* message);
  static void OnAudio(void* opaque, int sample_rate, int channels, int format,
                      int64_t pts_ms, const float* samples, int sample_count);

  int HandleVideo(int kind, int width, int height, const void* frame);
  void HandleAudio(int sample_rate, int channels, const float* samples,
                   int frames);
  void SetError(const std::string& msg);
  void EnsurePresentThread();
  void StopPresentThread();
  void PresentLoop();
  void SignalPresent();

  void* player_ = nullptr;
  SharedTextureBridge* bridge_ = nullptr;
  FrameReadyFn on_frame_;
  AudioOutput audio_;
  std::thread play_thread_;
  std::thread present_thread_;
  std::mutex present_mu_;
  std::condition_variable present_cv_;
  std::atomic<bool> present_running_{false};
  std::atomic<bool> present_pending_{false};
  mutable std::mutex mu_;
  std::string last_error_;
  std::atomic<uint64_t> video_frames_{0};
  std::atomic<uint64_t> present_ok_{0};
  std::atomic<uint64_t> audio_frames_{0};
  std::atomic<int> decode_hw_{-1};
  // Default off: audio-first; return 1 from on_video to skip GPU/CPU present.
  std::atomic<bool> video_enabled_{false};
};

}  // namespace lixh_player

#endif  // LIXH_PLAYER_PLAYER_SESSION_H_
