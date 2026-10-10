import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'lixh_player_platform_interface.dart';

class MethodChannelLixhPlayer extends LixhPlayerPlatform {
  @visibleForTesting
  final methodChannel = const MethodChannel('lixh_player');

  @override
  Future<String?> getPlatformVersion() async {
    return methodChannel.invokeMethod<String>('getPlatformVersion');
  }

  @override
  Future<VideoTextureInfo> createVideoTexture({
    required int width,
    required int height,
  }) async {
    final map = await methodChannel.invokeMapMethod<String, dynamic>(
      'createVideoTexture',
      {'width': width, 'height': height},
    );
    if (map == null) {
      throw PlatformException(
        code: 'texture_null',
        message: 'createVideoTexture returned null',
      );
    }
    return VideoTextureInfo(
      textureId: (map['textureId'] as num).toInt(),
      width: (map['width'] as num).toInt(),
      height: (map['height'] as num).toInt(),
      path: map['path'] as String? ?? 'unknown',
    );
  }

  @override
  Future<void> presentTestFrame({
    required double r,
    required double g,
    required double b,
  }) async {
    await methodChannel.invokeMethod<void>('presentTestFrame', {
      'r': r,
      'g': g,
      'b': b,
    });
  }

  @override
  Future<void> open(String url, {String? headers}) async {
    await methodChannel.invokeMethod<void>('open', {
      'url': url,
      if (headers != null && headers.isNotEmpty) 'headers': headers,
    });
  }

  @override
  Future<void> play() async {
    await methodChannel.invokeMethod<void>('play');
  }

  @override
  Future<void> stop() async {
    await methodChannel.invokeMethod<void>('stop');
  }

  @override
  Future<void> setVideoEnabled(bool enabled) async {
    await methodChannel.invokeMethod<void>('setVideoEnabled', {
      'enabled': enabled,
    });
  }

  @override
  Future<PlayerStats> getStats() async {
    final map = await methodChannel.invokeMapMethod<String, dynamic>('getStats');
    if (map == null) {
      return const PlayerStats(
        textureId: -1,
        videoFrames: 0,
        presentOk: 0,
        audioFrames: 0,
        decodeHw: -1,
        lastError: '',
      );
    }
    int n(String key) => (map[key] as num?)?.toInt() ?? 0;
    return PlayerStats(
      textureId: n('textureId') == 0 && map['textureId'] == null
          ? -1
          : (map['textureId'] as num?)?.toInt() ?? -1,
      videoFrames: n('videoFrames'),
      presentOk: n('presentOk'),
      audioFrames: n('audioFrames'),
      decodeHw: (map['decodeHw'] as num?)?.toInt() ?? -1,
      lastError: map['lastError'] as String? ?? '',
      droppedFrames: n('droppedFrames'),
      bytesRead: n('bytesRead'),
      lagMs: n('lagMs'),
      audioQueueMs: n('audioQueueMs'),
      videoWidth: n('videoWidth'),
      videoHeight: n('videoHeight'),
    );
  }

  @override
  Future<void> disposeVideoTexture() async {
    await methodChannel.invokeMethod<void>('disposeVideoTexture');
  }
}
