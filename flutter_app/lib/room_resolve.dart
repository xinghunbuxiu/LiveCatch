import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

const _nativePaths = MethodChannel('livecatch/native_paths');

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
  if (s.contains('找不到') && s.contains('lixh_resolve')) {
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

/// Resolve a live room page URL via stream-stack `lixh_resolve`.
Future<ResolvedRoom> resolveRoom(
  String roomUrl, {
  String? cookies,
  bool preferFlv = true,
  /// Prefer only_audio / audio_only FLV first (秒听-style listen).
  bool preferAudioOnly = true,
}) async {
  final raw = Platform.isAndroid
      ? await _resolveViaAndroidJni(roomUrl, cookies: cookies)
      : await _resolveViaProcess(roomUrl, cookies: cookies);

  final map = jsonDecode(raw) as Map<String, dynamic>;
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
    ..autoUncompress = false;
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

/// Android in-process JNI → `liblixh_stream_resolver.so` (no Process helper).
Future<String> _resolveViaAndroidJni(
  String roomUrl, {
  String? cookies,
}) async {
  final ready =
      await _nativePaths.invokeMethod<bool>('resolveNativeReady') ?? false;
  if (!ready) {
    throw StateError(
      'liblixh_stream_resolver 未加载。请先构建并打进 jniLibs:\n'
      '  pwsh flutter_app/android/bundle_lixh_resolve.ps1',
    );
  }
  try {
    final payload = await _nativePaths.invokeMethod<String>(
      'resolveRoom',
      <String, dynamic>{
        'url': roomUrl.trim(),
        if (cookies != null && cookies.isNotEmpty) 'cookies': cookies,
      },
    );
    if (payload == null || payload.isEmpty) {
      throw StateError('JNI resolve returned empty');
    }
    if (payload.startsWith('OK:')) {
      return payload.substring(3);
    }
    if (payload.startsWith('ERR:')) {
      throw StateError(formatResolveError(payload.substring(4)));
    }
    return payload;
  } on PlatformException catch (e) {
    throw StateError(formatResolveError(e.message ?? e.toString()));
  }
}

Future<String> _resolveViaProcess(
  String roomUrl, {
  String? cookies,
}) async {
  final exe = await findResolveExe();
  if (exe == null) {
    final bin = Platform.isWindows ? 'lixh_resolve.exe' : 'lixh_resolve';
    throw StateError(
      '找不到 $bin（房间解析器）。\n'
      '开发时请先构建并保证可执行文件在 PATH/仓库 target 下:\n'
      '  cargo build -p lixh-stream-resolver --bin lixh_resolve --release \\\n'
      '    --manifest-path src-tauri/lixh-stream-stack/Cargo.toml\n'
      'macOS 安装包需把二进制打进 App（CI 已自动 bundle）。\n'
      '也可设置环境变量 LIXH_RESOLVE_EXE 指向该文件。',
    );
  }

  final args = <String>[roomUrl.trim()];
  if (cookies != null && cookies.isNotEmpty) {
    args.addAll(['--cookies', cookies]);
  }

  final env = Map<String, String>.from(Platform.environment);
  if (Platform.isAndroid) {
    env['LD_LIBRARY_PATH'] = p.dirname(exe);
    for (final key in const [
      'http_proxy',
      'https_proxy',
      'HTTP_PROXY',
      'HTTPS_PROXY',
      'ALL_PROXY',
      'all_proxy',
      'no_proxy',
      'NO_PROXY',
    ]) {
      env.remove(key);
    }
  }

  final result = await Process.run(
    exe,
    args,
    environment: env,
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
  );
  if (result.exitCode != 0) {
    var err = (result.stderr as String).trim();
    if (err.startsWith('lixh_resolve:')) {
      err = err.substring('lixh_resolve:'.length).trim();
    }
    throw StateError(
      formatResolveError(
        err.isEmpty ? '房间解析失败 (exit ${result.exitCode})' : err,
      ),
    );
  }

  final raw = (result.stdout as String).trim();
  if (raw.isEmpty) {
    throw StateError('lixh_resolve returned empty stdout');
  }
  return raw;
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

Future<String?> findResolveExe() async {
  final fromEnv = Platform.environment['LIXH_RESOLVE_EXE'];
  if (fromEnv != null && fromEnv.isNotEmpty && await File(fromEnv).exists()) {
    return fromEnv;
  }

  // Android uses JNI resolveRoom — Process helper is desktop-only.
  if (Platform.isAndroid) return null;

  final names = Platform.isWindows
      ? const ['lixh_resolve.exe']
      : const ['lixh_resolve'];

  final exePath = Platform.resolvedExecutable;
  final exeDir = File(exePath).parent.path;
  final candidates = <String>[
    for (final name in names) p.join(exeDir, name),
  ];

  // macOS .app: Contents/MacOS/<bin> (same dir as main executable).
  if (Platform.isMacOS) {
    final contents = Directory(exeDir).parent.path; // …/Contents
    for (final name in names) {
      candidates.add(p.join(contents, 'MacOS', name));
      candidates.add(p.join(contents, 'Resources', name));
      candidates.add(p.join(contents, 'Helpers', name));
    }
  }

  for (final candidate in candidates) {
    if (await File(candidate).exists()) return candidate;
  }

  final roots = <String>{
    Directory.current.path,
    exeDir,
    File(exePath).parent.parent.parent.path, // walk up from .app/Contents/MacOS
  };
  for (final root in roots) {
    var dir = Directory(root);
    for (var i = 0; i < 10; i++) {
      for (final profile in const ['debug', 'release']) {
        for (final name in names) {
          final a = p.join(
            dir.path,
            'src-tauri',
            'lixh-stream-stack',
            'target',
            profile,
            name,
          );
          if (await File(a).exists()) return a;
          final b = p.join(dir.path, 'target', profile, name);
          if (await File(b).exists()) return b;
        }
      }
      final parent = dir.parent;
      if (parent.path == dir.path) break;
      dir = parent;
    }
  }
  return null;
}
