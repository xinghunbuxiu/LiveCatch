import 'package:flutter_test/flutter_test.dart';
import 'package:livecatch_app/live_input.dart';

void main() {
  test('extracts v.douyin short link from share card', () {
    const share =
        '#在抖音，记录美好生活#【德品文玩回血2号】正在直播，来和我一起支持Ta吧。'
        '复制下方链接，打开【抖音】，直接观看直播！ '
        'https://v.douyin.com/CbS4y7rfTQc/ 1@3.com :3pm';
    expect(
      extractLiveInput(share),
      'https://v.douyin.com/CbS4y7rfTQc/',
    );
    expect(isPasteableLiveClipboard(share), isTrue);
  });

  test('keeps live.douyin room URL', () {
    const url = 'https://live.douyin.com/123456789';
    expect(extractLiveInput(url), url);
    expect(isPasteableLiveClipboard(url), isTrue);
  });

  test('prefers live.douyin over unrelated http in mixed text', () {
    const text =
        'see https://example.com/foo and https://live.douyin.com/99 now';
    expect(extractLiveInput(text), 'https://live.douyin.com/99');
  });

  test('rejects random clipboard noise', () {
    expect(extractLiveInput('hello world'), isNull);
    expect(isPasteableLiveClipboard('https://example.com/page'), isFalse);
  });

  test('trims trailing punctuation from URL', () {
    expect(
      extractLiveInput('看这个 https://v.douyin.com/abc/！'),
      'https://v.douyin.com/abc/',
    );
  });

  test('extracts xiaohongshu / xhslink from share text', () {
    const share =
        '小红书直播中 https://www.xiaohongshu.com/user/profile/abc123 打开看看';
    expect(
      extractLiveInput(share),
      'https://www.xiaohongshu.com/user/profile/abc123',
    );
    expect(isPasteableLiveClipboard(share), isTrue);
    expect(
      extractLiveInput('https://xhslink.com/m/xyz'),
      'https://xhslink.com/m/xyz',
    );
  });
}
