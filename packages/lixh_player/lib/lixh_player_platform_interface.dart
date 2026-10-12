import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'lixh_player_method_channel.dart';

class VideoTextureInfo {
  const VideoTextureInfo({
    required this.textureId,
    required this.width,
    required this.height,
    required this.path,
  });

  final int textureId;
  final int width;
  final int height;
  final String path;
}

class PlayerStats {
  const PlayerStats({
    required this.textureId,
    required this.videoFrames,
    required this.presentOk,
    required this.audioFrames,
    required this.decodeHw,
    required this.lastError,
    this.droppedFrames = 0,
    this.bytesRead = 0,
    this.lagMs = 0,
    this.audioQueueMs = 0,
    this.videoWidth = 0,
    this.videoHeight = 0,
    this.presentMode = 0,
  });

  final int textureId;
  final int videoFrames;
  final int presentOk;
  final int audioFrames;
  final int decodeHw;
  final String lastError;
  final int droppedFrames;
  final int bytesRead;
  final int lagMs;
  final int audioQueueMs;
  final int videoWidth;
  final int videoHeight;
  /// 0=none, 1=MediaCodec Surface (zero-copy), 2=RGBA CPU path.
  final int presentMode;
}

abstract class LixhPlayerPlatform extends PlatformInterface {
  LixhPlayerPlatform() : super(token: _token);

  static final Object _token = Object();

  static LixhPlayerPlatform _instance = MethodChannelLixhPlayer();

  static LixhPlayerPlatform get instance => _instance;

  static set instance(LixhPlayerPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<String?> getPlatformVersion() {
    throw UnimplementedError('getPlatformVersion() has not been implemented.');
  }

  Future<VideoTextureInfo> createVideoTexture({
    required int width,
    required int height,
  }) {
    throw UnimplementedError('createVideoTexture() has not been implemented.');
  }

  Future<void> presentTestFrame({
    required double r,
    required double g,
    required double b,
  }) {
    throw UnimplementedError('presentTestFrame() has not been implemented.');
  }

  Future<void> open(String url, {String? headers}) {
    throw UnimplementedError('open() has not been implemented.');
  }

  Future<void> play() {
    throw UnimplementedError('play() has not been implemented.');
  }

  Future<void> stop() {
    throw UnimplementedError('stop() has not been implemented.');
  }

  Future<void> setVideoEnabled(bool enabled) {
    throw UnimplementedError('setVideoEnabled() has not been implemented.');
  }

  /// Live latency window in milliseconds (applied on next [open]).
  Future<void> setLatency({required int targetMs, required int maxMs}) {
    throw UnimplementedError('setLatency() has not been implemented.');
  }

  Future<PlayerStats> getStats() {
    throw UnimplementedError('getStats() has not been implemented.');
  }

  Future<void> disposeVideoTexture() {
    throw UnimplementedError('disposeVideoTexture() has not been implemented.');
  }
}
