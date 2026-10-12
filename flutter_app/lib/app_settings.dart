import 'package:shared_preferences/shared_preferences.dart';

/// User-tunable player preferences (persisted).
enum LatencyProfile {
  /// Slightly larger buffer — steadier on weak networks.
  smooth,

  /// Default balance.
  balanced,

  /// Smallest buffer — lowest lag, more risk of stalls.
  low,
}

extension LatencyProfileX on LatencyProfile {
  String get label => switch (this) {
        LatencyProfile.smooth => '流畅优先',
        LatencyProfile.balanced => '均衡',
        LatencyProfile.low => '低延迟',
      };

  String get hint => switch (this) {
        LatencyProfile.smooth => '缓冲更大，弱网更稳',
        LatencyProfile.balanced => '延迟与稳定性折中',
        LatencyProfile.low => '追帧更紧；音频约 120ms 起，卡顿时自动加厚',
      };

  /// Target / max live latency (ms) for native player when wired.
  /// Note: PCM starts near max(target×2, 120)ms and grows on underrun.
  (int targetMs, int maxMs) get latencyMs => switch (this) {
        LatencyProfile.smooth => (200, 600),
        LatencyProfile.balanced => (120, 400),
        // Tight video chase; audio cushion is applied separately in native.
        LatencyProfile.low => (80, 280),
      };
}

class AppSettings {
  AppSettings({
    this.startWithVideo = false,
    // Listen-first: avoid mid-play quality switches (each switch re-opens the stream).
    this.abrEnabled = false,
    this.preferFlv = true,
    // Balanced: less underrun risk than "low" on first install.
    this.latency = LatencyProfile.balanced,
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

  static Future<AppSettings> load() async {
    final p = await SharedPreferences.getInstance();
    final latName = p.getString(_kLatency);
    final latency = LatencyProfile.values.firstWhere(
      (e) => e.name == latName,
      orElse: () => LatencyProfile.balanced,
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
