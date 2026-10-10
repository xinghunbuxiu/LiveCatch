import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

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

/// True when [input] looks like a direct media URL (skip resolver).
bool looksLikeDirectStream(String input) {
  final u = input.trim().toLowerCase();
  if (u.isEmpty) return false;
  return u.contains('.m3u8') || u.contains('.flv') || u.contains('.mp4');
}

/// Resolve a live room page URL via `lixh_resolve` (same crate as Tauri).
Future<ResolvedRoom> resolveRoom(String roomUrl, {String? cookies}) async {
  final exe = await findResolveExe();
  if (exe == null) {
    throw StateError(
      '找不到 lixh_resolve.exe。请先在仓库执行:\n'
      '  cargo build -p lixh-stream-resolver --bin lixh_resolve \\\n'
      '    --manifest-path src-tauri/lixh-stream-stack/Cargo.toml\n'
      '或设置环境变量 LIXH_RESOLVE_EXE。',
    );
  }

  final args = <String>[roomUrl.trim()];
  if (cookies != null && cookies.isNotEmpty) {
    args.addAll(['--cookies', cookies]);
  }

  final result = await Process.run(
    exe,
    args,
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
  );
  if (result.exitCode != 0) {
    final err = (result.stderr as String).trim();
    throw StateError(err.isEmpty ? 'lixh_resolve exit ${result.exitCode}' : err);
  }

  final raw = (result.stdout as String).trim();
  if (raw.isEmpty) {
    throw StateError('lixh_resolve returned empty stdout');
  }

  final map = jsonDecode(raw) as Map<String, dynamic>;
  final isLive = map['is_live'] as bool? ?? false;
  if (!isLive) {
    throw StateError('直播已结束或不在播');
  }

  final picks = _selectStreams(map['streams'] as List<dynamic>? ?? const []);
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

/// Mirror Tauri `start_live_worker` candidate filtering (top 3, prefer FLV).
List<StreamPick> _selectStreams(List<dynamic> raw) {
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

  if (list.any((s) => s.format.toLowerCase().contains('flv'))) {
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

  final names = Platform.isWindows
      ? const ['lixh_resolve.exe']
      : const ['lixh_resolve'];

  final exeDir = File(Platform.resolvedExecutable).parent.path;
  for (final name in names) {
    final candidate = p.join(exeDir, name);
    if (await File(candidate).exists()) return candidate;
  }

  final roots = <String>{
    Directory.current.path,
    exeDir,
  };
  for (final root in roots) {
    var dir = Directory(root);
    for (var i = 0; i < 8; i++) {
      for (final profile in const ['debug', 'release']) {
        for (final name in names) {
          final a = p.join(dir.path, 'src-tauri', 'target', profile, name);
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
