import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

import 'license_api.dart';

/// Persisted license binding for this install.
class LicenseSession {
  LicenseSession._({
    required this.deviceId,
    this.code,
    this.active = false,
    this.lastMessage,
    this.lastHeartbeatAt,
  });

  final String deviceId;
  final String? code;
  final bool active;
  final String? lastMessage;
  final DateTime? lastHeartbeatAt;

  bool get hasCode => code != null && code!.trim().isNotEmpty;

  LicenseSession copyWith({
    String? deviceId,
    String? code,
    bool? active,
    String? lastMessage,
    DateTime? lastHeartbeatAt,
    bool clearCode = false,
  }) {
    return LicenseSession._(
      deviceId: deviceId ?? this.deviceId,
      code: clearCode ? null : (code ?? this.code),
      active: active ?? this.active,
      lastMessage: lastMessage ?? this.lastMessage,
      lastHeartbeatAt: lastHeartbeatAt ?? this.lastHeartbeatAt,
    );
  }

  static const _kDeviceId = 'rp_license_device_id';
  static const _kCode = 'rp_license_code';
  static const _kActive = 'rp_license_active';
  static const _kMessage = 'rp_license_message';
  static const _kHeartbeat = 'rp_license_heartbeat_ms';

  static Future<LicenseSession> load() async {
    final prefs = await SharedPreferences.getInstance();
    var deviceId = prefs.getString(_kDeviceId);
    if (deviceId == null || deviceId.isEmpty) {
      deviceId = _newDeviceId();
      await prefs.setString(_kDeviceId, deviceId);
    }
    final hb = prefs.getInt(_kHeartbeat);
    return LicenseSession._(
      deviceId: deviceId,
      code: prefs.getString(_kCode),
      active: prefs.getBool(_kActive) ?? false,
      lastMessage: prefs.getString(_kMessage),
      lastHeartbeatAt:
          hb == null ? null : DateTime.fromMillisecondsSinceEpoch(hb),
    );
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kDeviceId, deviceId);
    if (code == null || code!.isEmpty) {
      await prefs.remove(_kCode);
    } else {
      await prefs.setString(_kCode, code!);
    }
    await prefs.setBool(_kActive, active);
    if (lastMessage == null) {
      await prefs.remove(_kMessage);
    } else {
      await prefs.setString(_kMessage, lastMessage!);
    }
    if (lastHeartbeatAt == null) {
      await prefs.remove(_kHeartbeat);
    } else {
      await prefs.setInt(_kHeartbeat, lastHeartbeatAt!.millisecondsSinceEpoch);
    }
  }

  /// Activate [code] on this device.
  Future<LicenseSession> activate(LicenseApi api, String code) async {
    final trimmed = code.trim();
    if (trimmed.isEmpty) {
      throw LicenseApiException('请输入授权码');
    }
    final res = await api.activate(
      code: trimmed,
      deviceId: deviceId,
      deviceName: 'LiveCatch',
    );
    final next = copyWith(
      code: trimmed,
      active: true,
      lastMessage: res.message ?? '激活成功',
      lastHeartbeatAt: DateTime.now(),
    );
    await next.save();
    return next;
  }

  Future<LicenseSession> heartbeat(LicenseApi api) async {
    if (!hasCode) return this;
    final res = await api.heartbeat(
      code: code!,
      deviceId: deviceId,
      deviceName: 'LiveCatch',
    );
    final next = copyWith(
      active: true,
      lastMessage: res.message ?? '已在线',
      lastHeartbeatAt: DateTime.now(),
    );
    await next.save();
    return next;
  }

  Future<LicenseSession> unbind(LicenseApi api) async {
    if (hasCode) {
      await api.unbind(code: code!, deviceId: deviceId);
    }
    final next = copyWith(
      clearCode: true,
      active: false,
      lastMessage: '已解绑',
    );
    await next.save();
    return next;
  }

  static String _newDeviceId() {
    final r = Random.secure();
    final bytes = List<int>.generate(16, (_) => r.nextInt(256));
    // UUID-ish without extra deps.
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    String hex(int b) => b.toRadixString(16).padLeft(2, '0');
    final h = bytes.map(hex).join();
    return 'lc-${h.substring(0, 8)}-${h.substring(8, 12)}-'
        '${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20, 32)}';
  }
}
