#include "audio_output.h"

#include <algorithm>
#include <cstring>

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <mmreg.h>
#include <mmdeviceapi.h>
#include <audioclient.h>

#ifndef KSDATAFORMAT_SUBTYPE_IEEE_FLOAT
static const GUID KSDATAFORMAT_SUBTYPE_IEEE_FLOAT = {
    0x00000003, 0x0000, 0x0010, {0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71}};
#endif
#ifndef KSDATAFORMAT_SUBTYPE_PCM
static const GUID KSDATAFORMAT_SUBTYPE_PCM = {
    0x00000001, 0x0000, 0x0010, {0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71}};
#endif

namespace lixh_player {
namespace {

template <typename T>
void SafeRelease(T** p) {
  if (p && *p) {
    (*p)->Release();
    *p = nullptr;
  }
}

bool IsFloatFormat(const WAVEFORMATEX* fmt) {
  if (!fmt) return false;
  if (fmt->wFormatTag == WAVE_FORMAT_IEEE_FLOAT) return true;
  if (fmt->wFormatTag == WAVE_FORMAT_EXTENSIBLE && fmt->cbSize >= 22) {
    const auto* ext = reinterpret_cast<const WAVEFORMATEXTENSIBLE*>(fmt);
    return ext->SubFormat == KSDATAFORMAT_SUBTYPE_IEEE_FLOAT;
  }
  return false;
}

bool IsPcm16Format(const WAVEFORMATEX* fmt) {
  if (!fmt) return false;
  if (fmt->wFormatTag == WAVE_FORMAT_PCM && fmt->wBitsPerSample == 16) {
    return true;
  }
  if (fmt->wFormatTag == WAVE_FORMAT_EXTENSIBLE && fmt->cbSize >= 22) {
    const auto* ext = reinterpret_cast<const WAVEFORMATEXTENSIBLE*>(fmt);
    return ext->SubFormat == KSDATAFORMAT_SUBTYPE_PCM &&
           fmt->wBitsPerSample == 16;
  }
  return false;
}

}  // namespace

AudioOutput::AudioOutput() = default;

AudioOutput::~AudioOutput() { Stop(); }

void AudioOutput::ClearQueue() {
  std::lock_guard<std::mutex> lock(mu_);
  r_ = w_ = count_ = 0;
}

void AudioOutput::Flush() { ClearQueue(); }

void AudioOutput::SetMaxQueueMs(int ms) {
  // Floor: chase target can be 80ms; PCM needs more to avoid WASAPI underruns.
  if (ms < 160) ms = 160;
  if (ms > 2000) ms = 2000;
  std::lock_guard<std::mutex> lock(mu_);
  max_queue_ms_ = ms;
  const int rate = out_rate_ > 0 ? out_rate_ : src_rate_;
  const int ch = out_channels_ > 0 ? out_channels_ : src_channels_;
  size_t next = static_cast<size_t>(std::max(1, rate)) *
                static_cast<size_t>(std::max(1, ch)) *
                static_cast<size_t>(ms) / 1000;
  if (next < 2048) next = 2048;
  max_queue_ = next;
  if (ring_cap_ > 0 && ring_cap_ < max_queue_) {
    ring_.assign(max_queue_, 0.f);
    ring_cap_ = max_queue_;
    r_ = w_ = count_ = 0;
  } else if (ring_cap_ > 0) {
    const size_t trim_at = max_queue_ + max_queue_ / 4;
    const size_t min_keep =
        static_cast<size_t>(std::max(1, ch)) *
        static_cast<size_t>(std::max(1, rate)) * 80 / 1000;
    while (count_ > trim_at && count_ > min_keep) {
      size_t drop = static_cast<size_t>(std::max(1, ch)) *
                    static_cast<size_t>(std::max(1, rate / 50));
      if (drop > count_ - min_keep) drop = count_ - min_keep;
      if (drop == 0) break;
      r_ = (r_ + drop) % ring_cap_;
      count_ -= drop;
    }
  }
}

size_t AudioOutput::RingSpace() const {
  return ring_cap_ > count_ ? ring_cap_ - count_ : 0;
}

size_t AudioOutput::RingCount() const { return count_; }

void AudioOutput::RingWrite(const float* data, size_t n) {
  if (!data || n == 0 || ring_cap_ == 0) {
    return;
  }
  size_t off = 0;
  while (off < n) {
    size_t chunk = n - off;
    const size_t to_end = ring_cap_ - w_;
    if (chunk > to_end) {
      chunk = to_end;
    }
    if (chunk > RingSpace()) {
      chunk = RingSpace();
    }
    if (chunk == 0) {
      break;
    }
    std::memcpy(ring_.data() + w_, data + off, chunk * sizeof(float));
    w_ = (w_ + chunk) % ring_cap_;
    count_ += chunk;
    off += chunk;
  }
}

size_t AudioOutput::RingRead(float* dst, size_t n) {
  if (!dst || n == 0 || count_ == 0) {
    return 0;
  }
  size_t got = 0;
  while (got < n && count_ > 0) {
    size_t chunk = n - got;
    if (chunk > count_) {
      chunk = count_;
    }
    const size_t to_end = ring_cap_ - r_;
    if (chunk > to_end) {
      chunk = to_end;
    }
    std::memcpy(dst + got, ring_.data() + r_, chunk * sizeof(float));
    r_ = (r_ + chunk) % ring_cap_;
    count_ -= chunk;
    got += chunk;
  }
  return got;
}

int AudioOutput::queued_ms() const {
  std::lock_guard<std::mutex> lock(mu_);
  const int ch = out_channels_ > 0 ? out_channels_ : (src_channels_ > 0 ? src_channels_ : 2);
  const int rate = out_rate_ > 0 ? out_rate_ : (src_rate_ > 0 ? src_rate_ : 48000);
  if (ch <= 0 || rate <= 0 || count_ == 0) {
    return 0;
  }
  const size_t frames = count_ / static_cast<size_t>(ch);
  return static_cast<int>((frames * 1000ull) / static_cast<unsigned>(rate));
}

void AudioOutput::SetError(const std::string& msg) {
  std::lock_guard<std::mutex> lock(mu_);
  last_error_ = msg;
}

std::string AudioOutput::last_error() const {
  std::lock_guard<std::mutex> lock(mu_);
  return last_error_;
}

bool AudioOutput::Start() {
  std::lock_guard<std::mutex> life(lifecycle_mu_);
  if (running_.load()) {
    return true;
  }
  // Stop without taking lifecycle_mu_ again — inline shutdown of any stale state.
  running_.store(false);
  if (thread_.joinable()) {
    thread_.join();
  }
  if (client_) {
    static_cast<IAudioClient*>(client_)->Stop();
  }
  SafeRelease(reinterpret_cast<IAudioRenderClient**>(&render_));
  SafeRelease(reinterpret_cast<IAudioClient**>(&client_));
  if (event_) {
    CloseHandle(static_cast<HANDLE>(event_));
    event_ = nullptr;
  }
  buffer_frames_ = 0;
  ClearQueue();

  HRESULT hr = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  if (FAILED(hr) && hr != RPC_E_CHANGED_MODE) {
    SetError("CoInitializeEx failed");
    return false;
  }

  IMMDeviceEnumerator* enumerator = nullptr;
  hr = CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
                        __uuidof(IMMDeviceEnumerator),
                        reinterpret_cast<void**>(&enumerator));
  if (FAILED(hr) || !enumerator) {
    SetError("MMDeviceEnumerator create failed");
    return false;
  }

  IMMDevice* device = nullptr;
  hr = enumerator->GetDefaultAudioEndpoint(eRender, eConsole, &device);
  SafeRelease(&enumerator);
  if (FAILED(hr) || !device) {
    SetError("no default audio endpoint");
    return false;
  }

  IAudioClient* client = nullptr;
  hr = device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr,
                        reinterpret_cast<void**>(&client));
  SafeRelease(&device);
  if (FAILED(hr) || !client) {
    SetError("IAudioClient activate failed");
    return false;
  }

  WAVEFORMATEX* mix = nullptr;
  hr = client->GetMixFormat(&mix);
  if (FAILED(hr) || !mix) {
    SafeRelease(&client);
    SetError("GetMixFormat failed");
    return false;
  }

  if (IsFloatFormat(mix)) {
    out_kind_ = SampleKind::Float32;
  } else if (IsPcm16Format(mix)) {
    out_kind_ = SampleKind::Pcm16;
  } else {
    CoTaskMemFree(mix);
    SafeRelease(&client);
    SetError("unsupported mix format (need float or pcm16)");
    return false;
  }

  out_rate_ = static_cast<int>(mix->nSamplesPerSec);
  out_channels_ = static_cast<int>(mix->nChannels);

  HANDLE event = CreateEventW(nullptr, FALSE, FALSE, nullptr);
  // Event-driven shared mode — wakes as soon as the endpoint needs data.
  const REFERENCE_TIME buffer_duration = 25 * 10000;  // 25ms
  hr = client->Initialize(AUDCLNT_SHAREMODE_SHARED,
                          AUDCLNT_STREAMFLAGS_EVENTCALLBACK, buffer_duration, 0,
                          mix, nullptr);
  if (SUCCEEDED(hr) && event) {
    hr = client->SetEventHandle(event);
    if (FAILED(hr)) {
      CloseHandle(event);
      event = nullptr;
      SafeRelease(&client);
      // Recreate client for polling fallback.
      IMMDeviceEnumerator* enumerator2 = nullptr;
      IMMDevice* device2 = nullptr;
      CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
                       __uuidof(IMMDeviceEnumerator),
                       reinterpret_cast<void**>(&enumerator2));
      if (enumerator2) {
        enumerator2->GetDefaultAudioEndpoint(eRender, eConsole, &device2);
        SafeRelease(&enumerator2);
      }
      if (device2) {
        device2->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr,
                          reinterpret_cast<void**>(&client));
        SafeRelease(&device2);
      }
      WAVEFORMATEX* mix2 = nullptr;
      if (client && SUCCEEDED(client->GetMixFormat(&mix2)) && mix2) {
        hr = client->Initialize(AUDCLNT_SHAREMODE_SHARED, 0, buffer_duration, 0,
                                mix2, nullptr);
        CoTaskMemFree(mix2);
      } else {
        hr = E_FAIL;
      }
    }
  } else {
    if (event) {
      CloseHandle(event);
      event = nullptr;
    }
    if (!client) {
      CoTaskMemFree(mix);
      SetError("IAudioClient Initialize failed");
      return false;
    }
    hr = client->Initialize(AUDCLNT_SHAREMODE_SHARED, 0, buffer_duration, 0, mix,
                            nullptr);
  }
  CoTaskMemFree(mix);
  mix = nullptr;

  if (FAILED(hr) || !client) {
    if (event) CloseHandle(event);
    SafeRelease(&client);
    SetError("IAudioClient Initialize failed");
    return false;
  }

  UINT32 buffer_frames = 0;
  client->GetBufferSize(&buffer_frames);

  IAudioRenderClient* render = nullptr;
  hr = client->GetService(__uuidof(IAudioRenderClient),
                          reinterpret_cast<void**>(&render));
  if (FAILED(hr) || !render) {
    if (event) CloseHandle(event);
    SafeRelease(&client);
    SetError("GetService IAudioRenderClient failed");
    return false;
  }

  hr = client->Start();
  if (FAILED(hr)) {
    if (event) CloseHandle(event);
    SafeRelease(&render);
    SafeRelease(&client);
    SetError("IAudioClient Start failed");
    return false;
  }

  client_ = client;
  render_ = render;
  event_ = event;
  buffer_frames_ = buffer_frames;
  // App-side PCM cap from latency target (updated by SetMaxQueueMs).
  max_queue_ = static_cast<size_t>(std::max(1, out_rate_)) *
               static_cast<size_t>(std::max(1, out_channels_)) *
               static_cast<size_t>(std::max(40, max_queue_ms_)) / 1000;
  if (max_queue_ < 2048) {
    max_queue_ = 2048;
  }
  running_.store(true);
  ClearQueue();
  SetError("");
  thread_ = std::thread([this]() { RenderLoop(); });
  return true;
}

void AudioOutput::Stop() {
  std::lock_guard<std::mutex> life(lifecycle_mu_);
  running_.store(false);
  if (event_) {
    SetEvent(static_cast<HANDLE>(event_));
  }
  if (client_) {
    static_cast<IAudioClient*>(client_)->Stop();
  }
  if (thread_.joinable()) {
    thread_.join();
  }
  SafeRelease(reinterpret_cast<IAudioRenderClient**>(&render_));
  SafeRelease(reinterpret_cast<IAudioClient**>(&client_));
  if (event_) {
    CloseHandle(static_cast<HANDLE>(event_));
    event_ = nullptr;
  }
  buffer_frames_ = 0;
  ClearQueue();
}

void AudioOutput::Push(const float* samples, int frames, int channels,
                       int sample_rate) {
  if (!samples || frames <= 0 || channels <= 0 || sample_rate <= 0) {
    return;
  }
  if (!running_.load()) {
    Start();
  }
  if (!running_.load()) {
    return;
  }

  const int src_ch = channels;
  const int dst_ch = out_channels_ > 0 ? out_channels_ : src_ch;
  const int src_rate = sample_rate;
  const int dst_rate = out_rate_ > 0 ? out_rate_ : src_rate;
  const int src_frames = frames;
  int dst_frames = src_frames;
  if (src_rate != dst_rate) {
    dst_frames = static_cast<int>(
        (static_cast<int64_t>(src_frames) * dst_rate + src_rate - 1) / src_rate);
  }
  if (dst_frames <= 0) {
    return;
  }

  std::vector<float> chunk(static_cast<size_t>(dst_frames) * dst_ch);
  if (src_rate == dst_rate && src_ch == dst_ch) {
    std::memcpy(chunk.data(), samples,
                sizeof(float) * static_cast<size_t>(src_frames) * src_ch);
  } else if (dst_frames == 1) {
    for (int ch = 0; ch < dst_ch; ++ch) {
      const int sch = std::min(ch, src_ch - 1);
      chunk[static_cast<size_t>(ch)] = samples[sch];
    }
  } else {
    for (int i = 0; i < dst_frames; ++i) {
      const double pos = (static_cast<double>(i) * (src_frames - 1)) /
                         std::max(1, dst_frames - 1);
      const int i0 = static_cast<int>(pos);
      const int i1 = std::min(i0 + 1, src_frames - 1);
      const float frac = static_cast<float>(pos - i0);
      for (int ch = 0; ch < dst_ch; ++ch) {
        const int sch = std::min(ch, src_ch - 1);
        const float a0 = samples[i0 * src_ch + sch];
        const float a1 = samples[i1 * src_ch + sch];
        chunk[static_cast<size_t>(i) * dst_ch + ch] = a0 + (a1 - a0) * frac;
      }
    }
  }

  std::lock_guard<std::mutex> lock(mu_);
  src_rate_ = sample_rate;
  src_channels_ = channels;
  if (ring_cap_ < max_queue_) {
    ring_.assign(max_queue_, 0.f);
    ring_cap_ = max_queue_;
    r_ = w_ = count_ = 0;
  }
  // Hysteresis: trim only past 125% of cap; keep ≥~80ms to avoid crackle.
  const size_t cap = max_queue_ < ring_cap_ ? max_queue_ : ring_cap_;
  const size_t trim_at = cap + cap / 4;
  const size_t min_keep =
      static_cast<size_t>(std::max(1, out_channels_)) *
      static_cast<size_t>(std::max(1, out_rate_)) * 80 / 1000;
  while (count_ + chunk.size() > trim_at && count_ > min_keep) {
    size_t drop = static_cast<size_t>(std::max(1, out_channels_)) *
                  static_cast<size_t>(std::max(1, out_rate_ / 50));
    if (drop > count_ - min_keep) {
      drop = count_ - min_keep;
    }
    if (drop == 0 || ring_cap_ == 0) {
      break;
    }
    r_ = (r_ + drop) % ring_cap_;
    count_ -= drop;
  }
  RingWrite(chunk.data(), chunk.size());
}

void AudioOutput::RenderLoop() {
  const HRESULT com_hr = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  const bool com_owned = SUCCEEDED(com_hr);

  auto* client = static_cast<IAudioClient*>(client_);
  auto* render = static_cast<IAudioRenderClient*>(render_);

  auto* wake = static_cast<HANDLE>(event_);
  while (running_.load()) {
    if (wake) {
      WaitForSingleObject(wake, 40);
    } else {
      Sleep(2);
    }
    if (!running_.load() || !client || !render) {
      break;
    }

    UINT32 padding = 0;
    if (FAILED(client->GetCurrentPadding(&padding))) {
      continue;
    }
    const UINT32 available =
        buffer_frames_ > padding ? buffer_frames_ - padding : 0;
    if (available == 0) {
      continue;
    }

    BYTE* data = nullptr;
    if (FAILED(render->GetBuffer(available, &data)) || !data) {
      continue;
    }

    const int ch = out_channels_ > 0 ? out_channels_ : 2;
    const size_t need = static_cast<size_t>(available) * static_cast<size_t>(ch);

    {
      std::lock_guard<std::mutex> lock(mu_);
      if (out_kind_ == SampleKind::Float32) {
        auto* out = reinterpret_cast<float*>(data);
        const size_t have = RingRead(out, need);
        if (have < need) {
          std::memset(out + have, 0, (need - have) * sizeof(float));
        }
      } else {
        thread_local std::vector<float> tmp;
        if (tmp.size() < need) {
          tmp.resize(need);
        }
        const size_t have = RingRead(tmp.data(), need);
        auto* out = reinterpret_cast<int16_t*>(data);
        for (size_t i = 0; i < have; ++i) {
          float s = tmp[i];
          if (s > 1.f) s = 1.f;
          if (s < -1.f) s = -1.f;
          out[i] = static_cast<int16_t>(s * 32767.f);
        }
        if (have < need) {
          std::memset(out + have, 0, (need - have) * sizeof(int16_t));
        }
      }
    }

    render->ReleaseBuffer(available, 0);
  }

  if (com_owned) {
    CoUninitialize();
  }
}

}  // namespace lixh_player
