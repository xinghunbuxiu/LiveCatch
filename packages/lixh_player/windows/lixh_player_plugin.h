#ifndef FLUTTER_PLUGIN_LIXH_PLAYER_PLUGIN_H_
#define FLUTTER_PLUGIN_LIXH_PLAYER_PLUGIN_H_

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/texture_registrar.h>

#include <atomic>
#include <cstdint>
#include <memory>
#include <string>

#include "player_session.h"
#include "shared_texture.h"

namespace lixh_player {

class LixhPlayerPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar);

  explicit LixhPlayerPlugin(flutter::TextureRegistrar* textures);

  virtual ~LixhPlayerPlugin();

  LixhPlayerPlugin(const LixhPlayerPlugin&) = delete;
  LixhPlayerPlugin& operator=(const LixhPlayerPlugin&) = delete;

  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

 private:
  int64_t CreateVideoTexture(uint32_t width, uint32_t height);
  bool PresentTestFrame(float r, float g, float b);
  bool OpenUrl(const std::string& url, const std::string& headers);
  bool Play();
  void StopPlayback();
  void SetVideoEnabled(bool enabled);
  void SetLatency(int target_ms, int max_ms);
  void DisposeVideoTexture();
  flutter::EncodableMap StatsMap() const;
  void NotifyFrameAvailable();

  flutter::TextureRegistrar* textures_ = nullptr;
  std::shared_ptr<SharedTextureBridge> bridge_;
  std::unique_ptr<flutter::TextureVariant> texture_variant_;
  std::unique_ptr<PlayerSession> session_;
  int64_t texture_id_ = -1;
  std::atomic<int64_t> last_notify_ms_{0};
};

}  // namespace lixh_player

#endif  // FLUTTER_PLUGIN_LIXH_PLAYER_PLUGIN_H_
