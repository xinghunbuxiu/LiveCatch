import 'dart:convert';

import 'package:http/http.dart' as http;

import 'rewardplay_config.dart';

class LicenseApiException implements Exception {
  LicenseApiException(this.message, {this.code});
  final String message;
  final int? code;

  @override
  String toString() => message;
}

class LicenseIntegrationStatus {
  const LicenseIntegrationStatus({
    required this.projectCode,
    required this.projectName,
    required this.licenseEnabled,
    required this.openApiEnabled,
    required this.ready,
  });

  final String projectCode;
  final String projectName;
  final bool licenseEnabled;
  final bool openApiEnabled;
  final bool ready;

  factory LicenseIntegrationStatus.fromJson(Map<String, dynamic> j) {
    return LicenseIntegrationStatus(
      projectCode: (j['projectCode'] ?? '').toString(),
      projectName: (j['projectName'] ?? '').toString(),
      licenseEnabled: j['licenseEnabled'] == true,
      openApiEnabled: j['openApiEnabled'] == true,
      ready: j['ready'] == true,
    );
  }
}

class LicensePackage {
  const LicensePackage({
    required this.packageCode,
    required this.packageName,
    required this.durationDays,
    required this.priceFen,
    this.durationMinutes,
    this.maxDevices,
  });

  final String packageCode;
  final String packageName;
  final int? durationDays;
  final int? durationMinutes;
  final int? maxDevices;
  final int priceFen;

  factory LicensePackage.fromJson(Map<String, dynamic> j) {
    int? asInt(Object? v) => v is int ? v : int.tryParse('$v');
    return LicensePackage(
      packageCode: (j['packageCode'] ?? '').toString(),
      packageName: (j['packageName'] ?? '').toString(),
      durationDays: asInt(j['durationDays']),
      durationMinutes: asInt(j['durationMinutes']),
      maxDevices: asInt(j['maxDevices']),
      priceFen: asInt(j['priceFen']) ?? 0,
    );
  }

  /// User-facing length. Prefer minutes from the server when present.
  String get durationLabel {
    final minutes = durationMinutes;
    if (minutes != null && minutes > 0) {
      if (minutes % (60 * 24) == 0) {
        final days = minutes ~/ (60 * 24);
        return days >= 365 && days % 365 == 0 ? '${days ~/ 365} 年' : '$days 天';
      }
      if (minutes % 60 == 0) return '${minutes ~/ 60} 小时';
      return '$minutes 分钟';
    }
    final days = durationDays;
    if (days == null || days <= 0) return '永久';
    if (days % 365 == 0) return '${days ~/ 365} 年';
    return '$days 天';
  }
}

class LicenseCheckoutContext {
  const LicenseCheckoutContext({
    required this.projectCode,
    required this.projectName,
    required this.packages,
    required this.paymentReady,
    this.paymentHint,
  });

  final String projectCode;
  final String projectName;
  final List<LicensePackage> packages;
  final bool paymentReady;
  final String? paymentHint;

  factory LicenseCheckoutContext.fromJson(Map<String, dynamic> j) {
    final raw = j['packages'];
    final packages = <LicensePackage>[];
    if (raw is List) {
      for (final e in raw) {
        if (e is Map<String, dynamic>) {
          packages.add(LicensePackage.fromJson(e));
        } else if (e is Map) {
          packages.add(LicensePackage.fromJson(Map<String, dynamic>.from(e)));
        }
      }
    }
    return LicenseCheckoutContext(
      projectCode: (j['projectCode'] ?? '').toString(),
      projectName: (j['projectName'] ?? '').toString(),
      packages: packages,
      paymentReady: j['paymentReady'] == true,
      paymentHint: j['paymentHint']?.toString(),
    );
  }
}

/// Parsed activate / heartbeat / detail payload from Open License.
class LicenseBindResult {
  const LicenseBindResult({
    required this.raw,
    this.message,
    this.success = true,
    this.result,
    this.packageCode,
    this.packageName,
    this.expiresAt,
    this.boundDeviceId,
    this.boundDeviceCount,
    this.maxDevices,
    this.statusLabel,
  });

  final Map<String, dynamic> raw;
  final String? message;
  final bool success;
  final String? result;
  final String? packageCode;
  final String? packageName;
  final DateTime? expiresAt;
  final String? boundDeviceId;
  final int? boundDeviceCount;
  final int? maxDevices;
  final String? statusLabel;

  factory LicenseBindResult.fromData(Map<String, dynamic> data, {String? fallbackMessage}) {
    final success = data['success'] != false;
    final result = (data['activateResult'] ?? data['heartbeatResult'] ?? data['unbindResult'])
        ?.toString();
    return LicenseBindResult(
      raw: data,
      message: fallbackMessage ?? data['message']?.toString() ?? result,
      success: success,
      result: result,
      packageCode: _nonEmpty(data['packageCode']),
      packageName: _nonEmpty(data['packageName']),
      expiresAt: parseExpiresAt(data['expiresAt']),
      boundDeviceId: _nonEmpty(data['boundDeviceId']),
      boundDeviceCount: _asInt(data['boundDeviceCount']),
      maxDevices: _asInt(data['maxDevices']),
      statusLabel: _nonEmpty(data['status']),
    );
  }

  static String? _nonEmpty(Object? v) {
    final s = v?.toString().trim();
    if (s == null || s.isEmpty) return null;
    return s;
  }

  static int? _asInt(Object? v) => v is int ? v : int.tryParse('$v');

  /// Open API returns `yyyy-MM-dd HH:mm:ss` (or ISO). Already includes admin extensions.
  static DateTime? parseExpiresAt(Object? raw) {
    if (raw == null) return null;
    final s = raw.toString().trim();
    if (s.isEmpty) return null;
    final iso = DateTime.tryParse(s.replaceFirst(' ', 'T'));
    if (iso != null) return iso;
    final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})[ T](\d{2}):(\d{2})(?::(\d{2}))?$')
        .firstMatch(s);
    if (m == null) return null;
    return DateTime(
      int.parse(m.group(1)!),
      int.parse(m.group(2)!),
      int.parse(m.group(3)!),
      int.parse(m.group(4)!),
      int.parse(m.group(5)!),
      int.parse(m.group(6) ?? '0'),
    );
  }
}

/// Open License client (Bearer Integration Token).
///
/// Activate / heartbeat / unbind **require** a stable [deviceId] (4–128 chars,
/// no placeholders) per RewardPlay Open API.
class LicenseApi {
  LicenseApi({
    http.Client? client,
    String? baseUrl,
    String? projectCode,
    String? integrationToken,
  })  : _client = client ?? http.Client(),
        _baseUrl = (baseUrl ?? kRewardPlayBaseUrl).replaceAll(RegExp(r'/+$'), ''),
        _projectCode = projectCode ?? kRewardPlayProjectCode,
        _token = integrationToken ?? kRewardPlayIntegrationToken;

  final http.Client _client;
  final String _baseUrl;
  final String _projectCode;
  final String _token;

  bool get hasToken => _token.isNotEmpty;
  String get projectCode => _projectCode;

  Map<String, String> get _headers => {
        'Accept': 'application/json',
        'Content-Type': 'application/json',
        if (_token.isNotEmpty) 'Authorization': 'Bearer $_token',
        'User-Agent': 'LiveCatch/0.48',
      };

  Future<Map<String, dynamic>> _decode(http.Response res) async {
    Map<String, dynamic> body;
    try {
      final decoded = jsonDecode(utf8.decode(res.bodyBytes));
      if (decoded is Map<String, dynamic>) {
        body = decoded;
      } else if (decoded is Map) {
        body = Map<String, dynamic>.from(decoded);
      } else {
        throw LicenseApiException('响应格式错误', code: res.statusCode);
      }
    } catch (e) {
      if (e is LicenseApiException) rethrow;
      throw LicenseApiException(
        '响应解析失败 (${res.statusCode})',
        code: res.statusCode,
      );
    }
    final code = body['code'];
    final ok = code == 200 || code == '200';
    if (!ok) {
      throw LicenseApiException(
        _friendlyServerMessage(body['message']?.toString() ?? '请求失败'),
        code: code is int ? code : res.statusCode,
      );
    }
    final data = body['data'];
    if (data is Map<String, dynamic>) return data;
    if (data is Map) return Map<String, dynamic>.from(data);
    return body;
  }

  static String _friendlyServerMessage(String raw) {
    switch (raw) {
      case 'bound':
      case 'already_bound_current_device':
        return '激活成功';
      case 'ok':
        return '权益有效';
      case 'device_mismatch':
        return '注册码已绑定其他设备，请先解绑或联系客服';
      case 'device_limit_reached':
        return '绑定设备数已达上限';
      case 'not_bound':
        return '本机尚未绑定该注册码';
      case 'unbound':
      case 'already_unbound':
        return '已解绑';
      default:
        return raw;
    }
  }

  Future<LicenseIntegrationStatus> integrationStatus() async {
    _ensureToken();
    final uri = Uri.parse('$_baseUrl/api/open/license/integration/status');
    final res = await _client.get(uri, headers: _headers);
    final data = await _decode(res);
    return LicenseIntegrationStatus.fromJson(data);
  }

  Future<LicenseCheckoutContext> checkoutContext() async {
    final uri = Uri.parse(
      '$_baseUrl/api/client/v1/license/context',
    ).replace(queryParameters: {'projectCode': _projectCode});
    final res = await _client.get(uri, headers: _headers);
    final data = await _decode(res);
    return LicenseCheckoutContext.fromJson(data);
  }

  Future<LicenseBindResult> activate({
    required String code,
    required String deviceId,
    String? deviceName,
  }) async {
    _ensureToken();
    final id = requireDeviceId(deviceId);
    final uri = Uri.parse('$_baseUrl/api/open/license/activate');
    final res = await _client.post(
      uri,
      headers: _headers,
      body: jsonEncode({
        'projectCode': _projectCode,
        'code': code.trim(),
        'deviceId': id,
        if (deviceName != null && deviceName.isNotEmpty) 'deviceName': deviceName,
      }),
    );
    final data = await _decode(res);
    final result = LicenseBindResult.fromData(
      data,
      fallbackMessage: _friendlyServerMessage(
        (data['activateResult'] ?? data['message'] ?? '激活成功').toString(),
      ),
    );
    if (!result.success) {
      throw LicenseApiException(
        result.message ?? '激活失败',
        code: res.statusCode,
      );
    }
    return result;
  }

  Future<LicenseBindResult> heartbeat({
    required String code,
    required String deviceId,
    String? deviceName,
  }) async {
    _ensureToken();
    final id = requireDeviceId(deviceId);
    final uri = Uri.parse('$_baseUrl/api/open/license/heartbeat');
    final res = await _client.post(
      uri,
      headers: _headers,
      body: jsonEncode({
        'projectCode': _projectCode,
        'code': code.trim(),
        'deviceId': id,
        if (deviceName != null && deviceName.isNotEmpty) 'deviceName': deviceName,
      }),
    );
    final data = await _decode(res);
    final result = LicenseBindResult.fromData(
      data,
      fallbackMessage: _friendlyServerMessage(
        (data['heartbeatResult'] ?? data['message'] ?? '权益有效').toString(),
      ),
    );
    if (!result.success) {
      throw LicenseApiException(
        result.message ?? '校验失败',
        code: res.statusCode,
      );
    }
    return result;
  }

  Future<void> unbind({
    required String code,
    required String deviceId,
  }) async {
    _ensureToken();
    final id = requireDeviceId(deviceId);
    final uri = Uri.parse('$_baseUrl/api/open/license/unbind');
    final res = await _client.post(
      uri,
      headers: _headers,
      body: jsonEncode({
        'projectCode': _projectCode,
        'code': code.trim(),
        'deviceId': id,
      }),
    );
    await _decode(res);
  }

  Future<LicenseBindResult> codeDetail({required String code}) async {
    _ensureToken();
    final uri = Uri.parse('$_baseUrl/api/open/license/code/detail').replace(
      queryParameters: {
        'projectCode': _projectCode,
        'code': code.trim(),
      },
    );
    final res = await _client.get(uri, headers: _headers);
    final data = await _decode(res);
    return LicenseBindResult.fromData(data);
  }

  /// Align with RewardPlay `LicenseDeviceRules.require`.
  static String requireDeviceId(String? raw) {
    final deviceId = (raw ?? '').trim();
    if (deviceId.length < 4 || deviceId.length > 128) {
      throw LicenseApiException('本机编号无效，请重启应用后重试');
    }
    const placeholders = {
      'unknown',
      'null',
      'undefined',
      'n/a',
      'na',
      'none',
      'test',
      'device',
      '0',
      '-',
    };
    if (placeholders.contains(deviceId.toLowerCase())) {
      throw LicenseApiException('本机编号无效，请重启应用后重试');
    }
    return deviceId;
  }

  void _ensureToken() {
    if (_token.isEmpty) {
      throw LicenseApiException(
        '暂时无法联网校验，请稍后重试或联系客服',
      );
    }
  }
}
