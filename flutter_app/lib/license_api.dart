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

class LicenseBindResult {
  const LicenseBindResult({
    required this.raw,
    this.message,
  });

  final Map<String, dynamic> raw;
  final String? message;
}

/// Open License client (Bearer Integration Token).
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
        (body['message'] ?? '请求失败').toString(),
        code: code is int ? code : res.statusCode,
      );
    }
    final data = body['data'];
    if (data is Map<String, dynamic>) return data;
    if (data is Map) return Map<String, dynamic>.from(data);
    return body;
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
    final uri = Uri.parse('$_baseUrl/api/open/license/activate');
    final res = await _client.post(
      uri,
      headers: _headers,
      body: jsonEncode({
        'projectCode': _projectCode,
        'code': code.trim(),
        'deviceId': deviceId,
        if (deviceName != null && deviceName.isNotEmpty) 'deviceName': deviceName,
      }),
    );
    final data = await _decode(res);
    return LicenseBindResult(raw: data, message: data['message']?.toString());
  }

  Future<LicenseBindResult> heartbeat({
    required String code,
    required String deviceId,
    String? deviceName,
  }) async {
    _ensureToken();
    final uri = Uri.parse('$_baseUrl/api/open/license/heartbeat');
    final res = await _client.post(
      uri,
      headers: _headers,
      body: jsonEncode({
        'projectCode': _projectCode,
        'code': code.trim(),
        'deviceId': deviceId,
        if (deviceName != null && deviceName.isNotEmpty) 'deviceName': deviceName,
      }),
    );
    final data = await _decode(res);
    return LicenseBindResult(raw: data, message: data['message']?.toString());
  }

  Future<void> unbind({
    required String code,
    required String deviceId,
  }) async {
    _ensureToken();
    final uri = Uri.parse('$_baseUrl/api/open/license/unbind');
    final res = await _client.post(
      uri,
      headers: _headers,
      body: jsonEncode({
        'projectCode': _projectCode,
        'code': code.trim(),
        'deviceId': deviceId,
      }),
    );
    await _decode(res);
  }

  Future<Map<String, dynamic>> codeDetail({required String code}) async {
    _ensureToken();
    final uri = Uri.parse('$_baseUrl/api/open/license/code/detail').replace(
      queryParameters: {
        'projectCode': _projectCode,
        'code': code.trim(),
      },
    );
    final res = await _client.get(uri, headers: _headers);
    return _decode(res);
  }

  void _ensureToken() {
    if (_token.isEmpty) {
      throw LicenseApiException(
        '未配置 REWARDPLAY_INTEGRATION_TOKEN（--dart-define）',
      );
    }
  }
}
