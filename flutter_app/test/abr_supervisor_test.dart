import 'package:flutter_test/flutter_test.dart';
import 'package:livecatch_app/abr_supervisor.dart';
import 'package:livecatch_app/room_resolve.dart';

StreamPick pick(String url, {int bitrate = 0, int priority = 0}) => StreamPick(
      url: url,
      format: 'flv',
      quality: 'q$bitrate',
      bitrate: bitrate,
      priority: priority,
    );

void main() {
  test('failure switches to next unused candidate', () {
    final s = AbrSupervisor(
      candidates: [pick('a', bitrate: 500), pick('b', bitrate: 1000)],
    );
    s.setCurrent(0);
    final a = s.reportFailure('decode');
    expect(a.kind, AbrActionKind.switchTo);
    expect(a.index, 1);
  });

  test('exhausted candidates request re-resolve', () {
    final s = AbrSupervisor(candidates: [pick('a'), pick('b')]);
    s.setCurrent(0);
    s.reportFailure('x');
    final a = s.reportFailure('y');
    expect(a.kind, AbrActionKind.reResolve);
  });

  test('healthy ticks upshift bitrate rung', () {
    final s = AbrSupervisor(
      candidates: [
        pick('lo', bitrate: 500),
        pick('hi', bitrate: 2000),
      ],
      healthyTicksForUpshift: 3,
      upshiftLagMs: 400,
    );
    s.setCurrent(0);
    AbrAction? last;
    var t = DateTime.utc(2026, 1, 1);
    for (var i = 1; i <= 3; i++) {
      t = t.add(const Duration(milliseconds: 500));
      last = s.observe(
        progress: i * 10,
        lagMs: 100,
        playing: true,
        now: t,
      );
    }
    expect(last!.kind, AbrActionKind.switchTo);
    expect(last.index, 1);
    expect(last.reason, contains('upshift'));
  });

  test('hard lag triggers downshift', () {
    final s = AbrSupervisor(
      candidates: [
        pick('lo', bitrate: 500),
        pick('hi', bitrate: 2000),
      ],
      hardStallMs: 1000,
    );
    s.setCurrent(1);
    var t = DateTime.utc(2026, 1, 1);
    s.observe(progress: 10, lagMs: 100, playing: true, now: t);
    t = t.add(const Duration(milliseconds: 500));
    final a = s.observe(progress: 10, lagMs: 2500, playing: true, now: t);
    expect(a.kind, AbrActionKind.switchTo);
    expect(a.index, 0);
  });

  test('brief no-progress under threshold keeps stream', () {
    final s = AbrSupervisor(
      candidates: [pick('a'), pick('b')],
      stallThresholdMs: 1200,
      hardStallMs: 3000,
      maxStalls: 2,
    );
    s.setCurrent(0);
    var t = DateTime.utc(2026, 1, 1);
    s.observe(progress: 10, lagMs: 100, playing: true, now: t);
    t = t.add(const Duration(milliseconds: 500));
    final a = s.observe(progress: 10, lagMs: 100, playing: true, now: t);
    expect(a.kind, AbrActionKind.keep);
  });

  test('wall-clock stall switches after hardStallMs', () {
    final s = AbrSupervisor(
      candidates: [pick('a'), pick('b')],
      stallThresholdMs: 1200,
      hardStallMs: 3000,
    );
    s.setCurrent(0);
    var t = DateTime.utc(2026, 1, 1);
    s.observe(progress: 10, lagMs: 100, playing: true, now: t);
    t = t.add(const Duration(milliseconds: 3200));
    final a = s.observe(progress: 10, lagMs: 100, playing: true, now: t);
    expect(a.kind, AbrActionKind.switchTo);
    expect(a.index, 1);
  });
}
