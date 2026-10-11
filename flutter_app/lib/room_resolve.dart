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
  });

  final String url;
  final String format;
  final String quality;
  final int bitrate;
  final int priority;

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
  if (s.contains('直播已结束') || s.contains('不在播')) {
    return '直播已结束或不在播';
  }
  return s.isEmpty ? '房间解析失败' : s;
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
  );
  if (picks.isEmpty) {
    throw StateError('解析器没有返回可播放的视频流');
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

/// Android in-process JNI (app UID). Falls back to Process if lib missing.
Future<String> _resolveViaAndroidJni(
  String roomUrl, {
  String? cookies,
}) async {
  try {
    final ready =
        await _nativePaths.invokeMethod<bool>('resolveNativeReady') ?? false;
    if (ready) {
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
    }
  } on PlatformException catch (e) {
    // Fall through to Process helper.
    if (e.code == 'no_native') {
      // ignore
    } else {
      // Still try Process once; if that also fails, surface JNI error.
      try {
        return await _resolveViaProcess(roomUrl, cookies: cookies);
      } catch (_) {
        throw StateError(formatResolveError(e.message ?? e.toString()));
      }
    }
  }
  return _resolveViaProcess(roomUrl, cookies: cookies);
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
      'Android 需先交叉编译并打进 jniLibs:\n'
      '  bash flutter_app/android/bundle_lixh_resolve.sh\n'
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

/// Candidate filtering for ABR (top 3; optionally prefer FLV).
List<StreamPick> _selectStreams(List<dynamic> raw, {bool preferFlv = true}) {
  var list = <StreamPick>[];
  for (final item in raw) {
    if (item is! Map) continue;
    final m = Map<String, dynamic>.from(item);
    final url = (m['url'] as String?)?.trim() ?? '';
    final audioOnly = m['audio_only'] as bool? ?? false;
    if (url.isEmpty || audioOnly || url.contains('only_audio=1')) continue;
    list.add(
      StreamPick(
        url: url,
        format: m['format'] as String? ?? '',
        quality: m['quality'] as String? ?? '',
        bitrate: (m['bitrate'] as num?)?.toInt() ?? 0,
        priority: (m['priority'] as num?)?.toInt() ?? 0,
      ),
    );
  }

  if (preferFlv && list.any((s) => s.format.toLowerCase().contains('flv'))) {
    list = list.where((s) => s.format.toLowerCase().contains('flv')).toList();
  }

  // Low latency: resolver priority first, then lower bitrate (not max).
  list.sort((a, b) {
    final p = a.priority.compareTo(b.priority);
    if (p != 0) return p;
    return a.bitrate.compareTo(b.bitrate);
  });
  if (list.length > 3) {
    list = list.sublist(0, 3);
  }
  return list;
}

Future<String?> findResolveExe() async {
  final fromEnv = Platform.environment['LIXH_RESOLVE_EXE'];
  if (fromEnv != null && fromEnv.isNotEmpty && await File(fromEnv).exists()) {
    return fromEnv;
  }

  // Android: packaged as jniLibs arm64-v8a/liblixh_resolve.so (executable ELF).
  if (Platform.isAndroid) {
    try {
      final path = await _nativePaths.invokeMethod<String>('lixhResolvePath');
      if (path != null && path.isNotEmpty && await File(path).exists()) {
        return path;
      }
    } on PlatformException {
      // Fall through to filesystem probes below.
    }
  }

  final names = Platform.isWindows
      ? const ['lixh_resolve.exe']
      : const ['lixh_resolve', 'liblixh_resolve.so'];

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
