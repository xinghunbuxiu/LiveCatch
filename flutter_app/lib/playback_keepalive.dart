import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Android foreground-service bridge so playback survives lock screen / background.
class PlaybackKeepAlive {
  PlaybackKeepAlive._();

  static const _channel = MethodChannel('livecatch/playback_keepalive');
  static bool _active = false;
  static void Function()? onStopFromNotification;

  static bool get isSupported => !kIsWeb && Platform.isAndroid;

  static void bind() {
    if (!isSupported) return;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'stopFromNotification') {
        onStopFromNotification?.call();
      }
    });
  }

  static Future<void> start({String? title, String? text}) async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod<void>('start', {
        'title': title ?? 'LiveCatch',
        'text': text ?? '正在播放',
      });
      _active = true;
    } catch (e) {
      debugPrint('[LiveCatch] keepalive start: $e');
    }
  }

  static Future<void> update({String? title, String? text}) async {
    if (!isSupported || !_active) return;
    try {
      await _channel.invokeMethod<void>('update', {
        'title': title ?? 'LiveCatch',
        'text': text ?? '正在播放',
      });
    } catch (e) {
      debugPrint('[LiveCatch] keepalive update: $e');
    }
  }

  static Future<void> stop() async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod<void>('stop');
    } catch (e) {
      debugPrint('[LiveCatch] keepalive stop: $e');
    } finally {
      _active = false;
    }
  }
}
