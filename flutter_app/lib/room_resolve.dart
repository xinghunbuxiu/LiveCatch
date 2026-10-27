import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:livecatch_app/resolve_config.dart';

/// Result of [resolveRoom] — room metadata + ranked playable stream URLs.
class ResolvedRoom {
  const ResolvedRoom({
    required this.platform,
    required this.siteUrl,
    required this.title,
    required this.artist,
    required this.isLive,
    required this.streamUrl,
    required this.protocol,
    required this.candidates,
    required this.headers,
  });

  final String platform;
  final String siteUrl;
  final String title;
  final String artist;
  final bool isLive;
  final String streamUrl;
  final String protocol;
  final List<StreamPick> candidates;
  final Map<String, String> headers;

  /// FFmpeg `headers` option value (`Key: Value\r\n...`).
  String get ffmpegHeaders {
    final map = Map<String, String>.from(headers);
    if (!map.keys.any((k) => k.toLowerCase() == 'referer') &&
        siteUrl.isNotEmpty) {
      map['Referer'] = siteUrl;
    }
    if (!map.keys.any((k) => k.toLowerCase() == 'user-agent')) {
      map['User-Agent'] =
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';
    }
    if (map.isEmpty) return '';
    final buf = StringBuffer();
    for (final e in map.entries) {
      buf.write('${e.key}: ${e.value}\r\n');
    }
    return buf.toString();
  }
}

class StreamPick {
  const StreamPick({
    required this.url,
    required this.format,
    required this.quality,
    required this.bitrate,
    required this.priority,
    this.audioOnly = false,
  });

  final String url;
  final String format;
  final String quality;
  final int bitrate;
  final int priority;
  /// CDN audio-only / only_audio=1 — best for listen-first latency.
  final bool audioOnly;

  String get protocol =>
      format.toLowerCase().contains('flv') ? 'FLV' : 'HLS';
}

/// Strip nested resolver/extractor noise into a short UI-facing message.
String formatResolveError(Object error) {
  var s = error.toString().trim();
  const prefixes = ['Bad state: ', 'Exception: ', 'StateError: '];
  for (final p in prefixes) {
    if (s.startsWith(p)) {
      s = s.substring(p.length).trim();
    }
  }
  // Drop common English chain prefixes left by older binaries.
  for (final p in [
    'resolve: ',
    'extract stream metadata: ',
    'validation error: ',
    'API error: ',
  ]) {
    final i = s.toLowerCase().indexOf(p.toLowerCase());
    if (i == 0) {
      s = s.substring(p.length).trim();
    } else if (i > 0) {
      // Prefer the leaf after the last known noise token.
      final leaf = s.substring(i + p.length).trim();
      if (leaf.isNotEmpty) s = leaf;
    }
  }
  if (s.contains('服务繁忙') || s.contains('繁忙')) {
    return '抖音接口繁忙，请确认直播间在播后稍后重试';
  }
  if (s.contains('Connection closed before full header') ||
      s.contains('Connection closed before full headers') ||
      s.contains('Connection reset by peer') ||
      s.contains('Broken pipe')) {
    return '解析服务连接被中断。若开了 Clash/VPN，请将解析服务器设为直连后重试';
  }
  if (s.contains('ClientException') && s.contains('uri=')) {
    return '解析服务请求失败（网络中断）。请检查 Clash/VPN 直连或稍后重试';
  }
  if (s.contains('error sending request') ||
      s.contains('网络请求失败') ||
      s.contains('certificate') ||
      s.contains('dns error')) {
    // Keep cause text — useful when Android TLS/network diverges from desktop.
    final compact = s
        .replaceAll(RegExp(r'\s+'), ' ')
        .replaceAll('error sending request for url', '请求失败');
    return compact.length > 180 ? '${compact.substring(0, 180)}…' : compact;
  }
  if (s.contains('解析服务') || s.contains('resolve server')) {
    return s;
  }
  // Ended / offline — keep wording obvious so it is not mistaken for a bug.
  if (s.contains('直播已结束') ||
      s.contains('不在播') ||
      s.contains('已下播') ||
      s.contains('主播已离开') ||
      s.contains('not live') ||
      s.contains('StreamerNotFound') ||
      s.contains('streamer not found')) {
    return '直播已结束或不在播';
  }
  if (s.contains('没有返回可播放') ||
      s.contains('没有可用的直播流') ||
      s.contains('没有可播放线路')) {
    return '没有可播放线路（直播可能已结束）';
  }
  if (s.contains('短链') && (s.contains('展开') || s.contains('跳转') || s.contains('web_rid'))) {
    return s;
  }
  // PlatformException(open_failed, DETAIL, …) from lixh_player.
  if (s.contains('open_failed') || s.contains('open failed')) {
    final m = RegExp(
      r'open_failed[,\s]+([^,\)]+)',
      caseSensitive: false,
    ).firstMatch(s);
    var detail = (m?.group(1) ?? '').trim();
    if (detail == 'null' ||
        detail.isEmpty ||
        detail.contains('lixh_player_open failed')) {
      // Also try plain "open failed: DETAIL" from our logs/wrappers.
      final m2 = RegExp(
        r'open failed[:\s]+(.+)$',
        caseSensitive: false,
      ).firstMatch(s);
      detail = (m2?.group(1) ?? '').trim();
    }
    if (detail.isNotEmpty &&
        detail != 'null' &&
        !detail.contains('lixh_player_open failed')) {
      final short =
          detail.length > 80 ? '${detail.substring(0, 80)}…' : detail;
      return '打开流失败：$short';
    }
    return '打开流失败（线路不可用或协议不支持，请换清晰度/网络后重试）';
  }
  return s.isEmpty ? '房间解析失败' : s;
}

/// True when [msg] means the room is offline / ended (not an app fault).
bool isLiveEndedResolveError(Object error) {
  final s = formatResolveError(error);
  return s.contains('直播已结束') ||
      s.contains('不在播') ||
      s.contains('可能已结束');
}

/// True when [input] looks like a direct media URL (skip resolver).
bool looksLikeDirectStream(String input) {
  final u = input.trim().toLowerCase();
  if (u.isEmpty) return false;
  return u.contains('.m3u8') || u.contains('.flv') || u.contains('.mp4');
}

/// Resolve a live room page URL via remote `lixh_resolve_server`.
Future<ResolvedRoom> resolveRoom(
  String roomUrl, {
  String? cookies,
  bool preferFlv = true,
  /// Prefer only_audio / audio_only FLV first (秒听-style listen).
  bool preferAudioOnly = true,
  /// RewardPlay entitlement forwarded to the resolver so it can refuse service
  /// to expired or unbound devices. The resolver holds the integration token;
  /// only these two identifiers travel from the client.
  String? licenseCode,
  String? deviceId,
}) async {
  final map = await _resolveViaRemote(
    roomUrl,
    cookies: cookies,
    licenseCode: licenseCode,
    deviceId: deviceId,
  );
  final isLive = map['is_live'] as bool? ?? false;
  if (!isLive) {
    throw StateError('直播已结束或不在播');
  }

  final picks = _selectStreams(
    map['streams'] as List<dynamic>? ?? const [],
    preferFlv: preferFlv,
    preferAudioOnly: preferAudioOnly,
  );
  if (picks.isEmpty) {
    // is_live can still be true while CDN lists are empty at end-of-stream.
    throw StateError('没有可播放线路（直播可能已结束）');
  }

  final headers = <String, String>{};
  final rawHeaders = map['headers'];
  if (rawHeaders is Map) {
    rawHeaders.forEach((k, v) {
      if (k == null || v == null) return;
      headers['$k'] = '$v';
    });
  }

  return ResolvedRoom(
    platform: map['platform'] as String? ?? '',
    siteUrl: map['site_url'] as String? ?? roomUrl,
    title: map['title'] as String? ?? '',
    artist: map['artist'] as String? ?? '',
    isLive: isLive,
    streamUrl: picks.first.url,
    protocol: picks.first.protocol,
    candidates: picks,
    headers: headers,
  );
}

/// Copy [room] with candidates reordered (e.g. after TTFB probe).
ResolvedRoom roomWithCandidates(ResolvedRoom room, List<StreamPick> picks) {
  if (picks.isEmpty) return room;
  return ResolvedRoom(
    platform: room.platform,
    siteUrl: room.siteUrl,
    title: room.title,
    artist: room.artist,
    isLive: room.isLive,
    streamUrl: picks.first.url,
    protocol: picks.first.protocol,
    candidates: picks,
    headers: room.headers,
  );
}

/// Parallel lightweight TTFB probe; reorder so the snappiest CDN is first.
///
/// Uses Range GET (not ICMP). Failures keep original relative order at the end.
Future<List<StreamPick>> rankCandidatesByProbe(
  List<StreamPick> candidates, {
  Map<String, String> headerMap = const {},
  String siteUrl = '',
  Duration timeout = const Duration(milliseconds: 1100),
}) async {
  if (candidates.length <= 1) return List<StreamPick>.from(candidates);

  final headers = <String, String>{};
  headerMap.forEach((k, v) {
    if (k.trim().isEmpty || v.trim().isEmpty) return;
    headers[k] = v;
  });
  if (!headers.keys.any((k) => k.toLowerCase() == 'referer') &&
      siteUrl.isNotEmpty) {
    headers['Referer'] = siteUrl;
  }
  if (!headers.keys.any((k) => k.toLowerCase() == 'user-agent')) {
    headers['User-Agent'] =
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';
  }

  final scored = await Future.wait(
    List.generate(candidates.length, (i) async {
      final ms = await _probeStreamTtfb(
        candidates[i].url,
        headers: headers,
        timeout: timeout,
      );
      return (i, ms);
    }),
  );

  scored.sort((a, b) {
    final aOk = a.$2 != null;
    final bOk = b.$2 != null;
    if (aOk != bOk) return aOk ? -1 : 1;
    if (aOk && bOk) {
      final c = a.$2!.compareTo(b.$2!);
      if (c != 0) return c;
    }
    return a.$1.compareTo(b.$1);
  });

  return [for (final s in scored) candidates[s.$1]];
}

Future<int?> _probeStreamTtfb(
  String url, {
  required Map<String, String> headers,
  required Duration timeout,
}) async {
  final uri = Uri.tryParse(url);
  if (uri == null || !(uri.isScheme('http') || uri.isScheme('https'))) {
    return null;
  }

  final sw = Stopwatch()..start();
  final client = HttpClient()
    ..connectionTimeout = timeout
    ..idleTimeout = timeout
    ..autoUncompress = false
    ..findProxy = (_) => 'DIRECT';
  try {
    final req = await client.openUrl('GET', uri).timeout(timeout);
    req.followRedirects = true;
    req.maxRedirects = 4;
    headers.forEach(req.headers.set);
    req.headers.set(HttpHeaders.rangeHeader, 'bytes=0-1');
    // Avoid holding a live FLV forever.
    req.headers.set(HttpHeaders.connectionHeader, 'close');

    final resp = await req.close().timeout(timeout);
    final ttfb = sw.elapsedMilliseconds;
    // Drain a tiny amount then abort so we don't pull the whole stream.
    try {
      await resp
          .take(1)
          .timeout(const Duration(milliseconds: 250))
          .drain<void>();
    } catch (_) {}
    try {
      await resp.detachSocket().then((s) => s.destroy());
    } catch (_) {}

    final code = resp.statusCode;
    if (code >= 200 && code < 400) return ttfb;
    // Some CDNs reject Range but still answer quickly — usable signal.
    if (code == 416 || code == 405) return ttfb;
    return null;
  } catch (_) {
    return null;
  } finally {
    client.close(force: true);
  }
}

bool _isTransientResolveTransportError(Object e) {
  final s = e.toString();
  return s.contains('Connection closed before full header') ||
      s.contains('Connection closed before full headers') ||
      s.contains('Connection reset by peer') ||
      s.contains('Broken pipe') ||
      s.contains('ClientException') ||
      s.contains('SocketException') ||
      s.contains('HttpException');
}

/// POST room URL to remote `lixh_resolve_server` → ResolvedStream JSON map.
Future<Map<String, dynamic>> _resolveViaRemote(
  String roomUrl, {
  String? cookies,
  String? licenseCode,
  String? deviceId,
}) async {
  final base = kResolveBaseUrl.replaceAll(RegExp(r'/+$'), '');
  final uri = Uri.parse('$base/v1/resolve');
  final headers = <String, String>{
    HttpHeaders.contentTypeHeader: 'application/json; charset=utf-8',
    HttpHeaders.acceptHeader: 'application/json',
    // Avoid sticky keep-alive through Clash/transparent proxies that drop
    // the first response headers on long Douyin expands.
    HttpHeaders.connectionHeader: 'close',
  };
  if (kResolveApiKey.isNotEmpty) {
    headers['X-Api-Key'] = kResolveApiKey;
  }

  final body = <String, dynamic>{'url': roomUrl.trim()};
  if (cookies != null && cookies.trim().isNotEmpty) {
    body['cookies'] = cookies.trim();
  }
  /* Entitlement proof for the resolver. Omitted when the build has no licence
   * wired, which keeps the old key-only flow working during rollout. */
  final code = licenseCode?.trim() ?? '';
  final device = deviceId?.trim() ?? '';
  if (code.isNotEmpty && device.isNotEmpty) {
    body['license_code'] = code;
    body['device_id'] = device;
  }
  final payload = jsonEncode(body);

  Object? lastErr;
  for (var attempt = 1; attempt <= 3; attempt++) {
    final io = HttpClient()
      ..connectionTimeout = const Duration(seconds: 12)
      ..idleTimeout = const Duration(seconds: 60)
      ..autoUncompress = true
      ..userAgent = 'LiveCatch/0.48'
      // Clash/VPN system proxy often 0-byte / mid-header kills resolve.
      // Dart HttpClient honors findProxy; force DIRECT for the resolve host.
      ..findProxy = (_) => 'DIRECT';
    final client = IOClient(io);
    try {
      final resp = await client
          .post(uri, headers: headers, body: payload)
          .timeout(const Duration(seconds: 45));
      final raw = utf8.decode(resp.bodyBytes).trim();
      if (resp.statusCode == 401) {
        throw StateError('解析服务鉴权失败');
      }
      if (resp.statusCode == 403) {
        /* The resolver refused service because the entitlement it was shown is
         * not active for this device. Surface it as a licence problem so the UI
         * sends the user to activation instead of showing a raw server string. */
        throw StateError('权益无效或已过期，请重新激活');
      }
      if (resp.statusCode == 503) {
        /* RewardPlay check itself failed (timeout / 5xx). Not a dead licence. */
        throw StateError('权益校验暂时不可用，请稍后重试');
      }
      if (resp.statusCode == 429) {
        throw StateError('请求过于频繁，请稍后再试');
      }
      if (resp.statusCode >= 400) {
        var msg = raw;
        try {
          final errMap = jsonDecode(raw);
          if (errMap is Map && errMap['error'] != null) {
            msg = '${errMap['error']}';
          }
        } catch (_) {}
        throw StateError(
          formatResolveError(
            msg.isEmpty ? '房间解析失败 (HTTP ${resp.statusCode})' : msg,
          ),
        );
      }
      if (raw.isEmpty) {
        throw StateError('解析服务返回为空');
      }
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        throw StateError('解析服务返回格式错误');
      }
      return decoded;
    } on TimeoutException {
      lastErr = StateError('解析服务超时');
    } on SocketException catch (e) {
      lastErr = StateError('解析服务不可达: $e');
    } on HttpException catch (e) {
      lastErr = StateError('解析服务请求失败: $e');
    } catch (e) {
      lastErr = e;
      if (e is StateError && !_isTransientResolveTransportError(e)) {
        rethrow;
      }
    } finally {
      client.close();
      io.close(force: true);
    }
    if (attempt < 3 && lastErr != null && _isTransientResolveTransportError(lastErr)) {
      await Future<void>.delayed(Duration(milliseconds: 350 * attempt));
      continue;
    }
    break;
  }
  throw StateError(formatResolveError(lastErr ?? '解析服务请求失败'));
}

/// Candidate filtering for ABR (top few; optionally prefer FLV / audio-only).
List<StreamPick> _selectStreams(
  List<dynamic> raw, {
  bool preferFlv = true,
  bool preferAudioOnly = true,
}) {
  var list = <StreamPick>[];
  for (final item in raw) {
    if (item is! Map) continue;
    final m = Map<String, dynamic>.from(item);
    final url = (m['url'] as String?)?.trim() ?? '';
    if (url.isEmpty) continue;
    final audioOnly = (m['audio_only'] as bool? ?? false) ||
        url.contains('only_audio=1');
    // Picture mode: skip pure-audio CDN rungs.
    if (!preferAudioOnly && audioOnly) continue;
    final quality = (m['quality'] as String?)?.trim() ?? '';
    // Douyin often returns an unusable "md" rung with bitrate 0.
    if (quality.toLowerCase() == 'md' &&
        ((m['bitrate'] as num?)?.toInt() ?? 0) <= 0) {
      continue;
    }
    list.add(
      StreamPick(
        url: url,
        format: m['format'] as String? ?? '',
        quality: quality,
        bitrate: (m['bitrate'] as num?)?.toInt() ?? 0,
        priority: (m['priority'] as num?)?.toInt() ?? 0,
        audioOnly: audioOnly,
      ),
    );
  }

  if (preferFlv && list.any((s) => s.format.toLowerCase().contains('flv'))) {
    list = list.where((s) => s.format.toLowerCase().contains('flv')).toList();
  }

  // Drop unknown 0bps rungs when real bitrates exist (ABR must not "upshift" into them).
  // Keep audio-only even at 0bps — CDN often omits bitrate for only_audio.
  if (list.any((s) => s.bitrate > 0 && !s.audioOnly)) {
    list = list
        .where((s) => s.audioOnly || s.bitrate > 0)
        .toList();
  }

  // Listen: audio-only first, then lean A/V. Picture ladder: priority + bitrate.
  list.sort((a, b) {
    if (preferAudioOnly) {
      final ao = (b.audioOnly ? 1 : 0).compareTo(a.audioOnly ? 1 : 0);
      if (ao != 0) return ao;
    }
    final p = a.priority.compareTo(b.priority);
    if (p != 0) return p;
    return a.bitrate.compareTo(b.bitrate);
  });

  if (preferAudioOnly && list.any((s) => s.audioOnly)) {
    // Keep all audio-only + up to 2 A/V rungs for later 开画面.
    final audio = list.where((s) => s.audioOnly).toList();
    final av = list.where((s) => !s.audioOnly).take(2).toList();
    list = [...audio, ...av];
  } else if (list.length > 3) {
    list = list.sublist(0, 3);
  }
  return list;
}
