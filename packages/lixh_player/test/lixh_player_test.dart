import 'package:flutter_test/flutter_test.dart';
import 'package:lixh_player/lixh_player.dart';
import 'package:lixh_player/lixh_player_platform_interface.dart';
import 'package:lixh_player/lixh_player_method_channel.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class MockLixhPlayerPlatform
    with MockPlatformInterfaceMixin
    implements LixhPlayerPlatform {
  @override
  Future<String?> getPlatformVersion() => Future.value('42');

  @override
  Future<VideoTextureInfo> createVideoTexture({
    required int width,
    required int height,
  }) =>
      Future.value(
        VideoTextureInfo(
          textureId: 1,
          width: width,
          height: height,
          path: 'mock',
        ),
      );

  @override
  Future<void> presentTestFrame({
    required double r,
    required double g,
    required double b,
  }) =>
      Future.value();

  @override
  Future<void> open(String url, {String? headers}) => Future.value();

  @override
  Future<void> play() => Future.value();

  @override
  Future<void> stop() => Future.value();

  @override
  Future<void> setVideoEnabled(bool enabled) => Future.value();

  @override
  Future<void> setLatency({required int targetMs, required int maxMs}) =>
      Future.value();

  @override
  Future<PlayerStats> getStats() => Future.value(
        const PlayerStats(
          textureId: -1,
          videoFrames: 0,
          presentOk: 0,
          audioFrames: 0,
          decodeHw: -1,
          lastError: '',
        ),
      );

  @override
  Future<void> disposeVideoTexture() => Future.value();
}

void main() {
  final LixhPlayerPlatform initialPlatform = LixhPlayerPlatform.instance;

  test('$MethodChannelLixhPlayer is the default instance', () {
    expect(initialPlatform, isInstanceOf<MethodChannelLixhPlayer>());
  });

  test('getPlatformVersion', () async {
    LixhPlayer lixhPlayerPlugin = LixhPlayer();
    MockLixhPlayerPlatform fakePlatform = MockLixhPlayerPlatform();
    LixhPlayerPlatform.instance = fakePlatform;

    expect(await lixhPlayerPlugin.getPlatformVersion(), '42');
  });
}
