import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:livecatch_app/douyin_expand.dart';

void main() {
  test('detects v.douyin short links', () {
    expect(looksLikeDouyinShortUrl('https://v.douyin.com/CbS4y7rfTQc/'), isTrue);
    expect(looksLikeDouyinShortUrl('https://live.douyin.com/976204288960'), isFalse);
    expect(looksLikeDouyinShortUrl('https://example.com/x'), isFalse);
  });

  test('parses reflow Location for room_id and sec_user_id', () {
    const loc =
        'https://webcast.amemv.com/douyin/webcast/reflow/7695563656410549033?'
        'sec_user_id=MS4wLjABAAAABo7TOjs0WGkWRxhjBGsb5UXArcfstqkMtBm9WOtF828PzATw8pTfI_GJ-n2_0RS5'
        '&utm_source=copy';
    final p = parseDouyinRedirect(loc);
    expect(p.roomId, '7695563656410549033');
    expect(
      p.secUserId,
      'MS4wLjABAAAABo7TOjs0WGkWRxhjBGsb5UXArcfstqkMtBm9WOtF828PzATw8pTfI_GJ-n2_0RS5',
    );
    expect(p.liveWebRid, isNull);
  });

  test('parses live.douyin Location directly', () {
    final p = parseDouyinRedirect(
      'https://live.douyin.com/976204288960?room_id=1&enter_from_merge=web_share_link',
    );
    expect(p.liveWebRid, '976204288960');
    expect(p.roomId, isNull);
  });

  test('extracts web_rid from reflow JSON', () {
    final decoded = jsonDecode('''
{
  "data": {
    "room": {
      "owner": { "web_rid": "976204288960", "display_id": "57202451292" }
    }
  }
}
''');
    expect(webRidFromReflowJson(decoded), '976204288960');
  });
}
