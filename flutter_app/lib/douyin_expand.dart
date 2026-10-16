import 'dart:convert';
import 'dart:io';

/// Expand Douyin share short links (`v.douyin.com/...`) to
/// `https://live.douyin.com/{web_rid}` (server resolve prefers room URLs).
///
/// Flow: short URL → 302 reflow Location → room/reflow/info → owner.web_rid.

const _mobileUa =
    'Mozilla/5.0 (Linux; Android 11; SAMSUNG SM-G973U) AppleWebKit/537.36 '
    '(KHTML, like Gecko) SamsungBrowser/14.2 Chrome/87.0.4280.141 Mobile Safari/537.36';

final _reflowRoomRe = RegExp(
  r'(?:webcast\.amemv\.com|iesdouyin\.com)[^?\s]*/(?:reflow|share/live)/(\d+)',
  caseSensitive: false,
);

final _liveRidRe = RegExp(
  r'live\.douyin\.com/([A-Za-z0-9_\-\.]+)',
  caseSensitive: false,
);

final _secUserRe = RegExp(
  r'(?:sec_user_id|sec_uid)=([^&]+)',
  caseSensitive: false,
);

bool looksLikeDouyinShortUrl(String url) {
  final l = url.trim().toLowerCase();
  if (l.isEmpty) return false;
  return l.contains('v.douyin.com/') ||
      l.contains('v.douyin.com?') ||
      (l.contains('iesdouyin.com') && l.contains('/share/'));
}

/// room_id + sec_user_id from a 302 Location, or a live.douyin web_rid.
({String? roomId, String? secUserId, String? liveWebRid}) parseDouyinRedirect(
  String location,
) {
  final live = _liveRidRe.firstMatch(location);
  if (live != null) {
    return (roomId: null, secUserId: null, liveWebRid: live.group(1));
  }
  final room = _reflowRoomRe.firstMatch(location);
  final sec = _secUserRe.firstMatch(location);
  String? secUid;
  if (sec != null) {
    secUid = Uri.decodeComponent(sec.group(1)!);
  }
  return (
    roomId: room?.group(1),
    secUserId: secUid,
    liveWebRid: null,
  );
}

/// Pull `data.room.owner.web_rid` from reflow/info JSON.
String? webRidFromReflowJson(Object? decoded) {
  if (decoded is! Map) return null;
  final data = decoded['data'];
  if (data is! Map) return null;
  final room = data['room'];
  if (room is! Map) return null;
  final owner = room['owner'];
  if (owner is! Map) return null;
  final rid = owner['web_rid'] ?? owner['display_id'];
  if (rid == null) return null;
  final s = '$rid'.trim();
  return s.isEmpty ? null : s;
}

/// Expand a Douyin short / share URL to `https://live.douyin.com/{web_rid}`.
///
/// Non-short URLs are returned unchanged. Throws [StateError] on failure.
Future<String> expandDouyinShortUrl(String input) async {
  final url = input.trim();
  if (!looksLikeDouyinShortUrl(url)) return url;

  final uri = Uri.tryParse(url);
  if (uri == null || !(uri.isScheme('http') || uri.isScheme('https'))) {
    throw StateError('无效的抖音短链');
  }

  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 12)
    ..idleTimeout = const Duration(seconds: 12)
    ..autoUncompress = true;
  try {
    final loc = await _fetchRedirectLocation(client, uri);
    final parsed = parseDouyinRedirect(loc);
    if (parsed.liveWebRid != null) {
      return 'https://live.douyin.com/${parsed.liveWebRid}';
    }
    final roomId = parsed.roomId;
    final sec = parsed.secUserId;
    if (roomId == null || roomId.isEmpty) {
      throw StateError('短链未返回直播间 ID');
    }
    if (sec == null || sec.isEmpty) {
      throw StateError('短链缺少 sec_user_id');
    }

    final webRid = await _fetchWebRid(client, roomId: roomId, secUserId: sec);
    return 'https://live.douyin.com/$webRid';
  } finally {
    client.close(force: true);
  }
}

Future<String> _fetchRedirectLocation(HttpClient client, Uri uri) async {
  final req = await client.openUrl('GET', uri);
  req.followRedirects = false;
  req.maxRedirects = 0;
  req.headers.set(HttpHeaders.userAgentHeader, _mobileUa);
  req.headers.set(HttpHeaders.acceptHeader, 'text/html,application/xhtml+xml');

  final resp = await req.close().timeout(const Duration(seconds: 12));
  try {
    await resp.drain<void>();
  } catch (_) {}

  final loc = resp.headers.value(HttpHeaders.locationHeader)?.trim();
  if (loc == null || loc.isEmpty) {
    throw StateError('抖音短链未返回跳转地址 (HTTP ${resp.statusCode})');
  }
  if (loc.startsWith('http://') || loc.startsWith('https://')) return loc;
  return uri.resolve(loc).toString();
}

Future<String> _fetchWebRid(
  HttpClient client, {
  required String roomId,
  required String secUserId,
}) async {
  final info = Uri.https(
    'webcast.amemv.com',
    '/webcast/room/reflow/info/',
    <String, String>{
      'type_id': '0',
      'live_id': '1',
      'room_id': roomId,
      'sec_user_id': secUserId,
      'app_id': '1128',
    },
  );
  final req = await client.openUrl('GET', info);
  req.followRedirects = true;
  req.headers.set(HttpHeaders.userAgentHeader, _mobileUa);
  req.headers.set(HttpHeaders.acceptHeader, 'application/json');
  req.headers.set(HttpHeaders.refererHeader, 'https://live.douyin.com/');

  final resp = await req.close().timeout(const Duration(seconds: 12));
  final body = await resp.transform(utf8.decoder).join();
  if (resp.statusCode < 200 || resp.statusCode >= 300) {
    throw StateError('获取直播间号失败 (HTTP ${resp.statusCode})');
  }
  late final Object? decoded;
  try {
    decoded = jsonDecode(body);
  } catch (_) {
    throw StateError('获取直播间号失败：响应不是 JSON');
  }
  final webRid = webRidFromReflowJson(decoded);
  if (webRid == null) {
    throw StateError('获取直播间号失败：响应中无 web_rid');
  }
  return webRid;
}
