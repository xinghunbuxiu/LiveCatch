import 'lixh_player_platform_interface.dart';

export 'lixh_player_platform_interface.dart'
    show VideoTextureInfo, PlayerStats;

/// LiveCatch native player bridge (Windows full; macOS/iOS/Android stubs).
class LixhPlayer {
  Future<String?> getPlatformVersion() {
    return LixhPlayerPlatform.instance.getPlatformVersion();
  }

  /// Creates a GPU-shared Flutter [Texture] (DxgiSharedHandle on Windows).
  Future<VideoTextureInfo> createVideoTexture({
    int width = 1280,
    int height = 720,
  }) {
    return LixhPlayerPlatform.instance.createVideoTexture(
      width: width,
      height: height,
    );
  }

  /// Smoke-test present: paints a solid color into the shared texture.
  Future<void> presentTestFrame({
    double r = 0.1,
    double g = 0.5,
    double b = 0.9,
  }) {
    return LixhPlayerPlatform.instance.presentTestFrame(r: r, g: g, b: b);
  }

  Future<void> open(String url, {String? headers}) {
    return LixhPlayerPlatform.instance.open(url, headers: headers);
  }

  Future<void> play() {
    return LixhPlayerPlatform.instance.play();
  }

  Future<void> stop() {
    return LixhPlayerPlatform.instance.stop();
  }

  /// When false (default), decode callbacks skip GPU/CPU present (audio-first).
  Future<void> setVideoEnabled(bool enabled) {
    return LixhPlayerPlatform.instance.setVideoEnabled(enabled);
  }

  /// Target / max live latency window (ms). Applied on the next [open].
  Future<void> setLatency({required int targetMs, required int maxMs}) {
    return LixhPlayerPlatform.instance.setLatency(
      targetMs: targetMs,
      maxMs: maxMs,
    );
  }

  /// Max listen catch-up rate (1.0–1.5). No-op / ignored while picture is on.
  Future<void> setPlayRate(double rate) {
    return LixhPlayerPlatform.instance.setPlayRate(rate);
  }

  Future<PlayerStats> getStats() {
    return LixhPlayerPlatform.instance.getStats();
  }

  Future<void> disposeVideoTexture() {
    return LixhPlayerPlatform.instance.disposeVideoTexture();
  }
}
