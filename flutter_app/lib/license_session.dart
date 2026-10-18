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
    this.packageCode,
    this.packageName,
    this.expiresAt,
    this.maxDevices,
    this.boundDeviceCount,
  });

  final String deviceId;
  final String? code;
  final bool active;
  final String? lastMessage;
  final DateTime? lastHeartbeatAt;
  final String? packageCode;
  final String? packageName;
  final DateTime? expiresAt;
  final int? maxDevices;
  final int? boundDeviceCount;

  bool get hasCode => code != null && code!.trim().isNotEmpty;

  bool get isExpired {
    final e = expiresAt;
    if (e == null) return false;
    return DateTime.now().isAfter(e);
  }

  /// Remaining time label; null when permanent / unknown.
  String? get remainingLabel {
    final e = expiresAt;
    if (e == null) return null;
    final now = DateTime.now();
    if (!e.isAfter(now)) return '已到期';
    final d = e.difference(now);
    if (d.inDays >= 1) return '剩余 ${d.inDays} 天';
    if (d.inHours >= 1) return '剩余 ${d.inHours} 小时';
    final mins = d.inMinutes;
    return '剩余 ${mins < 1 ? 1 : mins} 分钟';
  }

  String get expiryDisplay {
    final e = expiresAt;
    if (e == null) return '长期有效';
    final l = e.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${l.year}-${two(l.month)}-${two(l.day)} ${two(l.hour)}:${two(l.minute)}';
  }

  LicenseSession copyWith({
    String? deviceId,
    String? code,
    bool? active,
    String? lastMessage,
    DateTime? lastHeartbeatAt,
    String? packageCode,
    String? packageName,
    DateTime? expiresAt,
    int? maxDevices,
    int? boundDeviceCount,
    bool clearCode = false,
    bool clearEntitlement = false,
  }) {
    return LicenseSession._(
      deviceId: deviceId ?? this.deviceId,
      code: clearCode ? null : (code ?? this.code),
      active: active ?? this.active,
      lastMessage: lastMessage ?? this.lastMessage,
      lastHeartbeatAt: lastHeartbeatAt ?? this.lastHeartbeatAt,
      packageCode: clearEntitlement || clearCode
          ? null
          : (packageCode ?? this.packageCode),
      packageName: clearEntitlement || clearCode
          ? null
          : (packageName ?? this.packageName),
      expiresAt:
          clearEntitlement || clearCode ? null : (expiresAt ?? this.expiresAt),
      maxDevices: clearEntitlement || clearCode
          ? null
          : (maxDevices ?? this.maxDevices),
      boundDeviceCount: clearEntitlement || clearCode
          ? null
          : (boundDeviceCount ?? this.boundDeviceCount),
    );
  }

  static const _kDeviceId = 'rp_license_device_id';
  static const _kCode = 'rp_license_code';
  static const _kActive = 'rp_license_active';
  static const _kMessage = 'rp_license_message';
  static const _kHeartbeat = 'rp_license_heartbeat_ms';
  static const _kPackageCode = 'rp_license_package_code';
  static const _kPackageName = 'rp_license_package_name';
  static const _kExpiresAt = 'rp_license_expires_at_ms';
  static const _kMaxDevices = 'rp_license_max_devices';
  static const _kBoundCount = 'rp_license_bound_count';

  static Future<LicenseSession> load() async {
    final prefs = await SharedPreferences.getInstance();
    var deviceId = prefs.getString(_kDeviceId);
    if (deviceId == null || deviceId.isEmpty) {
      deviceId = _newDeviceId();
      await prefs.setString(_kDeviceId, deviceId);
    }
    // Re-issue if an old install somehow got a placeholder / too-short id.
    try {
      LicenseApi.requireDeviceId(deviceId);
    } catch (_) {
      deviceId = _newDeviceId();
      await prefs.setString(_kDeviceId, deviceId);
    }
    final hb = prefs.getInt(_kHeartbeat);
    final exp = prefs.getInt(_kExpiresAt);
    return LicenseSession._(
      deviceId: deviceId,
      code: prefs.getString(_kCode),
      active: prefs.getBool(_kActive) ?? false,
      lastMessage: prefs.getString(_kMessage),
      lastHeartbeatAt:
          hb == null ? null : DateTime.fromMillisecondsSinceEpoch(hb),
      packageCode: prefs.getString(_kPackageCode),
      packageName: prefs.getString(_kPackageName),
      expiresAt: exp == null ? null : DateTime.fromMillisecondsSinceEpoch(exp),
      maxDevices: prefs.getInt(_kMaxDevices),
      boundDeviceCount: prefs.getInt(_kBoundCount),
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
    if (packageCode == null || packageCode!.isEmpty) {
      await prefs.remove(_kPackageCode);
    } else {
      await prefs.setString(_kPackageCode, packageCode!);
    }
    if (packageName == null || packageName!.isEmpty) {
      await prefs.remove(_kPackageName);
    } else {
      await prefs.setString(_kPackageName, packageName!);
    }
    if (expiresAt == null) {
      await prefs.remove(_kExpiresAt);
    } else {
      await prefs.setInt(_kExpiresAt, expiresAt!.millisecondsSinceEpoch);
    }
    if (maxDevices == null) {
      await prefs.remove(_kMaxDevices);
    } else {
      await prefs.setInt(_kMaxDevices, maxDevices!);
    }
    if (boundDeviceCount == null) {
      await prefs.remove(_kBoundCount);
    } else {
      await prefs.setInt(_kBoundCount, boundDeviceCount!);
    }
  }

  LicenseSession _applyBind(LicenseBindResult res, {required String code}) {
    final expired = res.expiresAt != null &&
        DateTime.now().isAfter(res.expiresAt!);
    // Replace cached expiry with the server value, including a later extension
    // or a null (permanent) date. copyWith would keep the old timestamp.
    return LicenseSession._(
      deviceId: deviceId,
      code: code,
      active: res.success && !expired,
      lastMessage: res.message,
      lastHeartbeatAt: DateTime.now(),
      packageCode: res.packageCode,
      packageName: res.packageName,
      expiresAt: res.expiresAt,
      maxDevices: res.maxDevices,
      boundDeviceCount: res.boundDeviceCount,
    );
  }

  /// Activate [code] on this device (Open API requires [deviceId]).
  Future<LicenseSession> activate(LicenseApi api, String code) async {
    final trimmed = code.trim();
    if (trimmed.isEmpty) {
      throw LicenseApiException('请输入注册码');
    }
    final res = await api.activate(
      code: trimmed,
      deviceId: deviceId,
      deviceName: 'LiveCatch',
    );
    final next = _applyBind(res, code: trimmed);
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
    final next = _applyBind(res, code: code!);
    await next.save();
    return next;
  }

  Future<LicenseSession> unbind(LicenseApi api) async {
    if (hasCode) {
      await api.unbind(code: code!, deviceId: deviceId);
    }
    final next = copyWith(
      clearCode: true,
      clearEntitlement: true,
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
