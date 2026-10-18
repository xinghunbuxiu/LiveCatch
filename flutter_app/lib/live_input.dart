/// Normalize pasted live-room / share text into a single playable URL.
///
/// Handles Douyin share cards like:
/// `#在抖音…正在直播… https://v.douyin.com/CbS4y7rfTQc/ 1@3.com :3pm`

final _urlRe = RegExp(r'https?://[^\s<>"\x27]+', caseSensitive: false);

/// Strip trailing punctuation commonly stuck to pasted URLs.
String trimUrlTail(String url) {
  var u = url.trim();
  while (u.isNotEmpty) {
    final c = u.codeUnitAt(u.length - 1);
    // ASCII punctuation / Chinese full-width punctuation often glued on paste.
    if ((c >= 0x21 && c <= 0x2F) ||
        (c >= 0x3A && c <= 0x40) ||
        (c >= 0x5B && c <= 0x60) ||
        (c >= 0x7B && c <= 0x7E) ||
        c == 0x3002 || // 。
        c == 0xFF0C || // ，
        c == 0xFF01 || // ！
        c == 0xFF1F || // ？
        c == 0x201D || // ”
        c == 0x2019) {
      // Prefer keeping a trailing slash on short links.
      if (c == 0x2F /* / */) break;
      u = u.substring(0, u.length - 1);
      continue;
    }
    break;
  }
  return u;
}

/// Higher = more likely a live room / stream we should auto-paste.
int scoreLiveUrl(String url) {
  final l = url.toLowerCase();
  if (l.contains('.m3u8') || l.contains('.flv') || l.contains('.mp4')) {
    return 100;
  }
  if (l.contains('live.douyin.com')) return 90;
  if (l.contains('v.douyin.com')) return 85;
  if (l.contains('iesdouyin.com')) return 82;
  if (l.contains('douyin.com') &&
      (l.contains('/live') || l.contains('webcast') || l.contains('room'))) {
    return 80;
  }
  if (l.contains('douyin.com')) return 70;
  if (l.contains('xiaohongshu.com') ||
      l.contains('xhslink.com') ||
      l.contains('xhs.cn')) {
    return 75;
  }
  if (l.contains('live.bilibili.com') ||
      l.contains('huya.com') ||
      l.contains('douyu.com') ||
      l.contains('kuaishou.com') ||
      l.contains('twitch.tv') ||
      l.contains('youtube.com/') ||
      l.contains('youtu.be/')) {
    return 60;
  }
  if (l.startsWith('http://') || l.startsWith('https://')) return 10;
  return 0;
}

/// Extract the best live URL from free-form clipboard / share text.
///
/// Returns null when nothing looks pasteable (avoids hijacking random links).
String? extractLiveInput(String raw) {
  final text = raw.trim();
  if (text.isEmpty) return null;

  final urls = _urlRe
      .allMatches(text)
      .map((m) => trimUrlTail(m.group(0)!))
      .where((u) => u.isNotEmpty)
      .toList();
  if (urls.isEmpty) return null;

  urls.sort((a, b) => scoreLiveUrl(b).compareTo(scoreLiveUrl(a)));
  final best = urls.first;
  final score = scoreLiveUrl(best);

  // Single URL pasted as-is.
  if (urls.length == 1 && text == best) {
    return score >= 10 ? best : null;
  }

  // Share card / mixed text: require a live-ish host.
  if (score >= 60) return best;

  // Share cards often wrap short links even when score heuristics miss.
  final shareHints = text.contains('正在直播') ||
      text.contains('打开【抖音】') ||
      text.contains('抖音') ||
      text.contains('小红书') ||
      text.contains('直播');
  if (shareHints) {
    for (final u in urls) {
      final l = u.toLowerCase();
      if (l.contains('douyin.com') ||
          l.contains('xiaohongshu.com') ||
          l.contains('xhslink.com') ||
          l.contains('xhs.cn')) {
        return u;
      }
    }
  }

  return null;
}

/// True when clipboard text should be auto-filled into the URL field.
bool isPasteableLiveClipboard(String raw) {
  final u = extractLiveInput(raw);
  if (u == null) return false;
  return scoreLiveUrl(u) >= 60;
}
