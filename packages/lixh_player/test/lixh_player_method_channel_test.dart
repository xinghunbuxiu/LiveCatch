import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lixh_player/lixh_player_method_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final platform = MethodChannelLixhPlayer();
  const channel = MethodChannel('lixh_player');

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
          switch (methodCall.method) {
            case 'getPlatformVersion':
              return '42';
            case 'createVideoTexture':
              return {
                'textureId': 7,
                'width': 1280,
                'height': 720,
                'path': 'dxgi_shared_handle',
              };
            case 'presentTestFrame':
            case 'disposeVideoTexture':
              return true;
          }
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('getPlatformVersion', () async {
    expect(await platform.getPlatformVersion(), '42');
  });

  test('createVideoTexture', () async {
    final info = await platform.createVideoTexture(width: 1280, height: 720);
    expect(info.textureId, 7);
    expect(info.path, 'dxgi_shared_handle');
  });
}
