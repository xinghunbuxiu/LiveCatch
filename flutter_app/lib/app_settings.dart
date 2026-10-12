import 'package:shared_preferences/shared_preferences.dart';

/// User-tunable player preferences (persisted).
enum LatencyProfile {
  /// Slightly larger buffer — steadier on weak networks.
  smooth,

  /// Default balance for picture + audio.
  balanced,

  /// Tight chase; still keeps a modest PCM cushion.
  low,

  /// Listen race mode — shortest PCM/prime; more underrun risk.
  snap,
}

extension LatencyProfileX on LatencyProfile {
  String get label => switch (this) {
        LatencyProfile.smooth => '流畅优先',
        LatencyProfile.balanced => '均衡',
        LatencyProfile.low => '低延迟',
        LatencyProfile.snap => '听播极限',
      };

  String get hint => switch (this) {
        LatencyProfile.smooth => '缓冲更大，弱网更稳',
        LatencyProfile.balanced => '延迟与稳定性折中',
        LatencyProfile.low => '追帧更紧；音频约 100ms 起，卡顿时自动加厚',
        LatencyProfile.snap => '对标秒听听感：极短预缓冲，易刺啦时自动加厚',
      };

  /// Target / max live latency (ms) for native chase when wired.
  /// PCM/prime scale from target in native (listen-only goes leaner).
  (int targetMs, int maxMs) get latencyMs => switch (this) {
        LatencyProfile.smooth => (200, 600),
        LatencyProfile.balanced => (120, 400),
        LatencyProfile.low => (80, 280),
        LatencyProfile.snap => (40, 160),
      };

  /// When picture is off, shave chase one notch so audio isn't waiting on video.
  (int targetMs, int maxMs) latencyMsFor({required bool videoOn}) {
    final (t, m) = latencyMs;
    if (videoOn) return (t, m);
    // Already snap — keep as-is.
    if (this == LatencyProfile.snap) return (t, m);
    final nt = (t * 3) ~/ 4;
    final nm = (m * 3) ~/ 4;
    return (nt < 40 ? 40 : nt, nm < nt ? (nt < 40 ? 40 : nt) + 80 : nm);
  }
}

class AppSettings {
  AppSettings({
    this.startWithVideo = false,
    // Listen-first: avoid mid-play quality switches (each switch re-opens the stream).
    this.abrEnabled = false,
    this.preferFlv = true,
    // Race the listen edge by default (product is 抢听).
    this.latency = LatencyProfile.snap,
  });

  /// Open with video sink on (otherwise audio-first listen mode).
  bool startWithVideo;

  /// Allow AbrSupervisor to switch candidates at runtime.
  bool abrEnabled;

  /// Prefer FLV over HLS when both exist.
  bool preferFlv;

  LatencyProfile latency;

  static const _kVideo = 'cfg.startWithVideo';
  static const _kAbr = 'cfg.abrEnabled';
  static const _kFlv = 'cfg.preferFlv';
  static const _kLatency = 'cfg.latency';
  static const _kSnapMigrate = 'cfg.latencySnapMigrate1';

  static Future<AppSettings> load() async {
    final p = await SharedPreferences.getInstance();
    // One-shot: listen-first product pivot — bump old defaults to 听播极限.
    if (!(p.getBool(_kSnapMigrate) ?? false)) {
      await p.setBool(_kSnapMigrate, true);
      final prev = p.getString(_kLatency);
      if (prev == null || prev == 'balanced') {
        await p.setString(_kLatency, LatencyProfile.snap.name);
      }
    }
    final latName = p.getString(_kLatency);
    final latency = LatencyProfile.values.firstWhere(
      (e) => e.name == latName,
      orElse: () => LatencyProfile.snap,
    );
    return AppSettings(
      startWithVideo: p.getBool(_kVideo) ?? false,
      abrEnabled: p.getBool(_kAbr) ?? false,
      preferFlv: p.getBool(_kFlv) ?? true,
      latency: latency,
    );
  }

  Future<void> save() async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kVideo, startWithVideo);
    await p.setBool(_kAbr, abrEnabled);
    await p.setBool(_kFlv, preferFlv);
    await p.setString(_kLatency, latency.name);
  }

  AppSettings copyWith({
    bool? startWithVideo,
    bool? abrEnabled,
    bool? preferFlv,
    LatencyProfile? latency,
  }) {
    return AppSettings(
      startWithVideo: startWithVideo ?? this.startWithVideo,
      abrEnabled: abrEnabled ?? this.abrEnabled,
      preferFlv: preferFlv ?? this.preferFlv,
      latency: latency ?? this.latency,
    );
  }
}
