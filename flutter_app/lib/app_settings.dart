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
        LatencyProfile.low => '延迟最低，卡顿风险更高',
      };

  /// Target / max live latency (ms) for native player when wired.
  (int targetMs, int maxMs) get latencyMs => switch (this) {
        LatencyProfile.smooth => (280, 900),
        LatencyProfile.balanced => (160, 520),
        // Matches prior macOS engine default (tight live window).
        LatencyProfile.low => (120, 450),
      };
}

class AppSettings {
  AppSettings({
    this.startWithVideo = false,
    this.abrEnabled = true,
    this.preferFlv = true,
    // Default to former macOS live window so fresh installs stay snappy.
    this.latency = LatencyProfile.low,
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
      abrEnabled: p.getBool(_kAbr) ?? true,
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
