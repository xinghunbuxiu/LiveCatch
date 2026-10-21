#ifndef LIXH_PLAYER_AUDIO_OUTPUT_H_
#define LIXH_PLAYER_AUDIO_OUTPUT_H_

#include <atomic>
#include <chrono>
#include <cstdint>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace lixh_player {

// WASAPI shared-mode ring buffer. Push interleaved f32 PCM from
// lixh_player on_audio; a render thread drains to the default device.
class AudioOutput {
 public:
  AudioOutput();
  ~AudioOutput();

  AudioOutput(const AudioOutput&) = delete;
  AudioOutput& operator=(const AudioOutput&) = delete;

  bool Start();
  void Stop();

  // Cap app-side PCM backlog to roughly [ms] (same semantics as Android).
  void SetMaxQueueMs(int ms);

  // frames = samples per channel; samples are interleaved float [-1,1].
  void Push(const float* samples, int frames, int channels, int sample_rate);

  void Flush();
  /* Tip jump: drop queued PCM, keep primed for immediate new audio. */
  void FlushTip();

  // Buffered PCM waiting for WASAPI, milliseconds.
  int queued_ms() const;

  std::string last_error() const;

 private:
  enum class SampleKind { Float32, Pcm16 };

  void RenderLoop();
  void ClearQueue();
  void SetError(const std::string& msg);
  size_t RingSpace() const;
  size_t RingCount() const;
  void RingWrite(const float* data, size_t n);
  size_t RingRead(float* dst, size_t n);

  mutable std::mutex mu_;
  std::mutex lifecycle_mu_;  // serializes Start/Stop
  std::vector<float> ring_;
  size_t ring_cap_ = 0;
  size_t r_ = 0;
  size_t w_ = 0;
  size_t count_ = 0;
  size_t max_queue_ = 48000 * 2;
  int base_queue_ms_ = 120;
  int max_queue_ms_ = 120;
  bool primed_ = false;
  std::chrono::steady_clock::time_point last_underrun_{};
  std::chrono::steady_clock::time_point last_shrink_{};
  int src_rate_ = 48000;
  int src_channels_ = 2;
  std::string last_error_;

  std::thread thread_;
  std::atomic<bool> running_{false};
  void* client_ = nullptr;
  void* render_ = nullptr;
  void* event_ = nullptr;
  uint32_t buffer_frames_ = 0;
  int out_rate_ = 48000;
  int out_channels_ = 2;
  SampleKind out_kind_ = SampleKind::Float32;
};

}  // namespace lixh_player

#endif  // LIXH_PLAYER_AUDIO_OUTPUT_H_
