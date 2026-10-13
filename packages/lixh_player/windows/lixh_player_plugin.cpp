#include "lixh_player_plugin.h"

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <chrono>
#include <cstdio>
#include <memory>
#include <optional>
#include <string>

namespace lixh_player {

namespace {

std::optional<int64_t> ReadInt(const flutter::EncodableMap& map,
                               const std::string& key) {
  auto it = map.find(flutter::EncodableValue(key));
  if (it == map.end()) {
    return std::nullopt;
  }
  if (const auto* v = std::get_if<int32_t>(&it->second)) {
    return static_cast<int64_t>(*v);
  }
  if (const auto* v = std::get_if<int64_t>(&it->second)) {
    return *v;
  }
  return std::nullopt;
}

std::optional<double> ReadDouble(const flutter::EncodableMap& map,
                                 const std::string& key) {
  auto it = map.find(flutter::EncodableValue(key));
  if (it == map.end()) {
    return std::nullopt;
  }
  if (const auto* v = std::get_if<double>(&it->second)) {
    return *v;
  }
  if (const auto* v = std::get_if<int32_t>(&it->second)) {
    return static_cast<double>(*v);
  }
  if (const auto* v = std::get_if<int64_t>(&it->second)) {
    return static_cast<double>(*v);
  }
  return std::nullopt;
}

std::optional<std::string> ReadString(const flutter::EncodableMap& map,
                                      const std::string& key) {
  auto it = map.find(flutter::EncodableValue(key));
  if (it == map.end()) {
    return std::nullopt;
  }
  if (const auto* v = std::get_if<std::string>(&it->second)) {
    return *v;
  }
  return std::nullopt;
}

}  // namespace

// static
void LixhPlayerPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows* registrar) {
  auto channel =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          registrar->messenger(), "lixh_player",
          &flutter::StandardMethodCodec::GetInstance());

  auto plugin =
      std::make_unique<LixhPlayerPlugin>(registrar->texture_registrar());

  channel->SetMethodCallHandler(
      [plugin_pointer = plugin.get()](const auto& call, auto result) {
        plugin_pointer->HandleMethodCall(call, std::move(result));
      });

  registrar->AddPlugin(std::move(plugin));
}

LixhPlayerPlugin::LixhPlayerPlugin(flutter::TextureRegistrar* textures)
    : textures_(textures) {}

LixhPlayerPlugin::~LixhPlayerPlugin() { DisposeVideoTexture(); }

void LixhPlayerPlugin::NotifyFrameAvailable() {
  if (!textures_ || texture_id_ < 0) {
    return;
  }
  // Cap ~60 notify/s — flood + Impeller GLES was losing the EGL context.
  const int64_t now = std::chrono::duration_cast<std::chrono::milliseconds>(
                          std::chrono::steady_clock::now().time_since_epoch())
                          .count();
  int64_t prev = last_notify_ms_.load();
  if (now - prev < 12 && prev != 0) {
    return;
  }
  last_notify_ms_.store(now);
  textures_->MarkTextureFrameAvailable(texture_id_);
}

int64_t LixhPlayerPlugin::CreateVideoTexture(uint32_t width, uint32_t height) {
  DisposeVideoTexture();
  auto bridge = std::make_shared<SharedTextureBridge>();
  if (!bridge->Initialize(width, height)) {
    return -1;
  }
  // Placeholder so Texture is not empty black before first decode frame.
  bridge->PresentColor(0.02f, 0.02f, 0.02f);

  std::weak_ptr<SharedTextureBridge> weak = bridge;
  auto gpu_texture = flutter::GpuSurfaceTexture(
      kFlutterDesktopGpuSurfaceTypeDxgiSharedHandle,
      [weak](size_t /*width*/, size_t /*height*/)
          -> const FlutterDesktopGpuSurfaceDescriptor* {
        auto locked = weak.lock();
        if (!locked) {
          return nullptr;
        }
        return locked->Descriptor();
      });

  texture_variant_ =
      std::make_unique<flutter::TextureVariant>(std::move(gpu_texture));
  texture_id_ = textures_->RegisterTexture(texture_variant_.get());
  if (texture_id_ < 0) {
    texture_variant_.reset();
    return -1;
  }
  bridge_ = std::move(bridge);

  session_ = std::make_unique<PlayerSession>();
  session_->AttachTexture(bridge_.get(), [this]() { NotifyFrameAvailable(); });

  last_notify_ms_.store(0);
  textures_->MarkTextureFrameAvailable(texture_id_);
  return texture_id_;
}

bool LixhPlayerPlugin::PresentTestFrame(float r, float g, float b) {
  if (!bridge_ || texture_id_ < 0) {
    return false;
  }
  if (!bridge_->PresentColor(r, g, b)) {
    return false;
  }
  return textures_->MarkTextureFrameAvailable(texture_id_);
}

bool LixhPlayerPlugin::OpenUrl(const std::string& url,
                               const std::string& headers) {
  if (!session_) {
    return false;
  }
  std::fprintf(stderr, "[lixh] open url=%zu chars headers=%d\n", url.size(),
               headers.empty() ? 0 : 1);
  std::fflush(stderr);
  const bool ok = session_->Open(url, headers);
  if (!ok) {
    std::fprintf(stderr, "[lixh] open FAILED: %s\n",
                 session_->last_error().c_str());
    std::fflush(stderr);
  }
  return ok;
}

bool LixhPlayerPlugin::Play() {
  if (!session_) {
    return false;
  }
  std::fprintf(stderr, "[lixh] play\n");
  std::fflush(stderr);
  const bool ok = session_->Play();
  if (!ok) {
    std::fprintf(stderr, "[lixh] play FAILED: %s\n",
                 session_->last_error().c_str());
    std::fflush(stderr);
  }
  return ok;
}

void LixhPlayerPlugin::StopPlayback() {
  std::fprintf(stderr, "[lixh] stop\n");
  std::fflush(stderr);
  if (session_) {
    session_->Stop();
  }
}

void LixhPlayerPlugin::SetVideoEnabled(bool enabled) {
  std::fprintf(stderr, "[lixh] setVideoEnabled %s\n",
               enabled ? "true" : "false");
  std::fflush(stderr);
  if (session_) {
    session_->SetVideoEnabled(enabled);
  }
}

void LixhPlayerPlugin::SetLatency(int target_ms, int max_ms) {
  std::fprintf(stderr, "[lixh] setLatency target=%d max=%d\n", target_ms,
               max_ms);
  std::fflush(stderr);
  if (session_) {
    session_->SetLatency(target_ms, max_ms);
  }
}

void LixhPlayerPlugin::SetPlayRate(float rate) {
  if (session_) {
    session_->SetPlayRate(rate);
  }
}

void LixhPlayerPlugin::DisposeVideoTexture() {
  if (session_) {
    session_->Detach();
    session_.reset();
  }
  if (textures_ && texture_id_ >= 0) {
    textures_->UnregisterTexture(texture_id_);
  }
  texture_id_ = -1;
  texture_variant_.reset();
  bridge_.reset();
}

flutter::EncodableMap LixhPlayerPlugin::StatsMap() const {
  flutter::EncodableMap out;
  out[flutter::EncodableValue("textureId")] =
      flutter::EncodableValue(static_cast<int64_t>(texture_id_));
  auto put_i64 = [&](const char* key, int64_t v) {
    out[flutter::EncodableValue(key)] = flutter::EncodableValue(v);
  };
  auto put_i32 = [&](const char* key, int32_t v) {
    out[flutter::EncodableValue(key)] = flutter::EncodableValue(v);
  };
  if (!session_) {
    put_i64("videoFrames", 0);
    put_i64("presentOk", 0);
    put_i64("audioFrames", 0);
    put_i64("droppedFrames", 0);
    put_i64("bytesRead", 0);
    put_i64("lagMs", 0);
    put_i32("audioQueueMs", 0);
    put_i32("decodeHw", -1);
    put_i32("videoWidth", 0);
    put_i32("videoHeight", 0);
    out[flutter::EncodableValue("lastError")] = flutter::EncodableValue("");
    return out;
  }
  const auto s = session_->GetStats();
  put_i64("videoFrames", static_cast<int64_t>(s.video_frames));
  put_i64("presentOk", static_cast<int64_t>(s.present_ok));
  put_i64("audioFrames", static_cast<int64_t>(s.audio_frames));
  put_i64("droppedFrames", static_cast<int64_t>(s.dropped_frames));
  put_i64("bytesRead", static_cast<int64_t>(s.bytes_read));
  put_i64("lagMs", s.lag_ms);
  put_i32("audioQueueMs", s.audio_queue_ms);
  put_i32("decodeHw", s.decode_hw);
  put_i32("videoWidth", s.video_width);
  put_i32("videoHeight", s.video_height);
  out[flutter::EncodableValue("lastError")] =
      flutter::EncodableValue(s.last_error);
  return out;
}

void LixhPlayerPlugin::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const std::string& method = method_call.method_name();

  if (method == "createVideoTexture") {
    const auto* args =
        std::get_if<flutter::EncodableMap>(method_call.arguments());
    if (!args) {
      result->Error("bad_args", "Expected map with width/height");
      return;
    }
    auto width = ReadInt(*args, "width");
    auto height = ReadInt(*args, "height");
    if (!width || !height || *width <= 0 || *height <= 0) {
      result->Error("bad_args", "width/height required");
      return;
    }
    int64_t id = CreateVideoTexture(static_cast<uint32_t>(*width),
                                    static_cast<uint32_t>(*height));
    if (id < 0) {
      result->Error("texture_failed",
                    "Failed to create DXGI shared texture");
      return;
    }
    flutter::EncodableMap out;
    out[flutter::EncodableValue("textureId")] = flutter::EncodableValue(id);
    out[flutter::EncodableValue("width")] =
        flutter::EncodableValue(static_cast<int32_t>(*width));
    out[flutter::EncodableValue("height")] =
        flutter::EncodableValue(static_cast<int32_t>(*height));
    out[flutter::EncodableValue("path")] =
        flutter::EncodableValue("dxgi_shared_handle");
    result->Success(flutter::EncodableValue(out));
    return;
  }

  if (method == "presentTestFrame") {
    const auto* args =
        std::get_if<flutter::EncodableMap>(method_call.arguments());
    float r = 0.1f, g = 0.5f, b = 0.9f;
    if (args) {
      if (auto v = ReadDouble(*args, "r")) r = static_cast<float>(*v);
      if (auto v = ReadDouble(*args, "g")) g = static_cast<float>(*v);
      if (auto v = ReadDouble(*args, "b")) b = static_cast<float>(*v);
    }
    if (!PresentTestFrame(r, g, b)) {
      result->Error("present_failed", "No texture or present failed");
      return;
    }
    result->Success(flutter::EncodableValue(true));
    return;
  }

  if (method == "open") {
    const auto* args =
        std::get_if<flutter::EncodableMap>(method_call.arguments());
    auto url = args ? ReadString(*args, "url") : std::nullopt;
    if (!url || url->empty()) {
      result->Error("bad_args", "url required");
      return;
    }
    std::string headers;
    if (args) {
      if (auto h = ReadString(*args, "headers")) {
        headers = *h;
      }
    }
    if (!OpenUrl(*url, headers)) {
      std::string err = session_ ? session_->last_error() : "no session";
      result->Error("open_failed", err);
      return;
    }
    result->Success(flutter::EncodableValue(true));
    return;
  }

  if (method == "play") {
    if (!Play()) {
      std::string err = session_ ? session_->last_error() : "no session";
      result->Error("play_failed", err);
      return;
    }
    result->Success(flutter::EncodableValue(true));
    return;
  }

  if (method == "stop") {
    StopPlayback();
    result->Success(flutter::EncodableValue(true));
    return;
  }

  if (method == "setVideoEnabled") {
    const auto* args =
        std::get_if<flutter::EncodableMap>(method_call.arguments());
    bool enabled = false;
    if (args) {
      auto it = args->find(flutter::EncodableValue("enabled"));
      if (it != args->end()) {
        if (const auto* b = std::get_if<bool>(&it->second)) {
          enabled = *b;
        }
      }
    }
    SetVideoEnabled(enabled);
    result->Success(flutter::EncodableValue(true));
    return;
  }

  if (method == "setLatency") {
    const auto* args =
        std::get_if<flutter::EncodableMap>(method_call.arguments());
    auto target = args ? ReadInt(*args, "targetMs") : std::nullopt;
    auto maxv = args ? ReadInt(*args, "maxMs") : std::nullopt;
    if (!target || !maxv) {
      result->Error("bad_args", "targetMs and maxMs required");
      return;
    }
    SetLatency(static_cast<int>(*target), static_cast<int>(*maxv));
    result->Success(flutter::EncodableValue(true));
    return;
  }

  if (method == "setPlayRate") {
    const auto* args =
        std::get_if<flutter::EncodableMap>(method_call.arguments());
    double rate = 1.3;
    if (args) {
      auto it = args->find(flutter::EncodableValue("rate"));
      if (it != args->end()) {
        if (const auto* d = std::get_if<double>(&it->second)) {
          rate = *d;
        } else if (const auto* i = std::get_if<int32_t>(&it->second)) {
          rate = static_cast<double>(*i);
        }
      }
    }
    SetPlayRate(static_cast<float>(rate));
    result->Success(flutter::EncodableValue(true));
    return;
  }

  if (method == "getStats") {
    result->Success(flutter::EncodableValue(StatsMap()));
    return;
  }

  if (method == "disposeVideoTexture") {
    DisposeVideoTexture();
    result->Success(flutter::EncodableValue(true));
    return;
  }

  if (method == "getPlatformVersion") {
    result->Success(flutter::EncodableValue(
        "Windows DXGI shared texture + lixh-player-core"));
    return;
  }

  result->NotImplemented();
}

}  // namespace lixh_player
