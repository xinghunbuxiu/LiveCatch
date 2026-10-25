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
        LatencyProfile.low => '追帧更紧；听播约 50–80ms，卡顿短暂加厚后回落',
        LatencyProfile.snap => '听播优先：~90ms PCM，低延迟且连续；刺啦短暂加厚后回落',
      };

  /// Target / max live latency (ms) for native chase when wired.
  /// PCM/prime scale from target in native (listen-only goes leaner).
  (int targetMs, int maxMs) get latencyMs => switch (this) {
        LatencyProfile.smooth => (200, 600),
        LatencyProfile.balanced => (120, 400),
        LatencyProfile.low => (80, 280),
        // 70/200 → native PCM ~90ms: low delay + continuous speech.
        LatencyProfile.snap => (70, 200),
      };

  /// Listen keeps snap chase; picture lifts the floor so A/V decode doesn't stutter.
  (int targetMs, int maxMs) latencyMsFor({required bool videoOn}) {
    var (t, m) = latencyMs;
    if (videoOn) {
      if (t < 120) t = 120;
      if (m < 400) m = 400;
      return (t, m);
    }
    if (this == LatencyProfile.snap) return (t, m);
    final nt = (t * 3) ~/ 4;
    final nm = (m * 3) ~/ 4;
    return (nt < 70 ? 70 : nt, nm < nt ? (nt < 70 ? 70 : nt) + 100 : nm);
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
    /// Listen play-rate ceiling (1.0–1.5). Native stays ~1.0x when live,
    /// ramps toward this when backlog grows.
    // 1.0x: catch-up is PCM trim only. >1.0 linear stretch → 吱吱/变调.
    this.listenPlayRate = 1.0,
  });

  /// Discrete presets shown in the speed picker UI.
  static const List<double> listenPlayRatePresets = [1.0, 1.1, 1.2, 1.3, 1.5];

  static double snapListenPlayRate(double v) {
    var best = listenPlayRatePresets.first;
    var bestDist = (v - best).abs();
    for (final p in listenPlayRatePresets.skip(1)) {
      final d = (v - p).abs();
      if (d < bestDist) {
        best = p;
        bestDist = d;
      }
    }
    return best;
  }

  /// Open with video sink on (otherwise audio-first listen mode).
  bool startWithVideo;

  /// Allow AbrSupervisor to switch candidates at runtime.
  bool abrEnabled;

  /// Prefer FLV over HLS when both exist.
  bool preferFlv;

  LatencyProfile latency;

  /// Listen-only play-rate ceiling (picture caps at 1.15x).
  double listenPlayRate;

  static const _kVideo = 'cfg.startWithVideo';
  static const _kAbr = 'cfg.abrEnabled';
  static const _kFlv = 'cfg.preferFlv';
  static const _kLatency = 'cfg.latency';
  static const _kListenRate = 'cfg.listenPlayRate';
  static const _kSnapMigrate = 'cfg.latencySnapMigrate1';
  static const _kRate1xMigrate = 'cfg.listenRate1xMigrate1';

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
    // One-shot: kill persisted 1.2/1.3 — linear stretch caused 吱吱 BGM.
    if (!(p.getBool(_kRate1xMigrate) ?? false)) {
      await p.setBool(_kRate1xMigrate, true);
      await p.setDouble(_kListenRate, 1.0);
    }
    final latName = p.getString(_kLatency);
    final latency = LatencyProfile.values.firstWhere(
      (e) => e.name == latName,
      orElse: () => LatencyProfile.snap,
    );
    final rate = snapListenPlayRate(
      (p.getDouble(_kListenRate) ?? 1.0).clamp(1.0, 1.5),
    );
    return AppSettings(
      startWithVideo: p.getBool(_kVideo) ?? false,
      abrEnabled: p.getBool(_kAbr) ?? false,
      preferFlv: p.getBool(_kFlv) ?? true,
      latency: latency,
      listenPlayRate: rate,
    );
  }

  Future<void> save() async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kVideo, startWithVideo);
    await p.setBool(_kAbr, abrEnabled);
    await p.setBool(_kFlv, preferFlv);
    await p.setString(_kLatency, latency.name);
    await p.setDouble(
      _kListenRate,
      snapListenPlayRate(listenPlayRate.clamp(1.0, 1.5)),
    );
  }

  AppSettings copyWith({
    bool? startWithVideo,
    bool? abrEnabled,
    bool? preferFlv,
    LatencyProfile? latency,
    double? listenPlayRate,
  }) {
    return AppSettings(
      startWithVideo: startWithVideo ?? this.startWithVideo,
      abrEnabled: abrEnabled ?? this.abrEnabled,
      preferFlv: preferFlv ?? this.preferFlv,
      latency: latency ?? this.latency,
      listenPlayRate: listenPlayRate ?? this.listenPlayRate,
    );
  }
}
