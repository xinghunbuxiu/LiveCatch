import 'room_resolve.dart';

/// Actions for runtime bitrate / candidate switching (Flutter-side ABR).
enum AbrActionKind { keep, switchTo, reResolve }

class AbrAction {
  const AbrAction.keep()
      : kind = AbrActionKind.keep,
        index = null,
        reason = '';

  const AbrAction.switchTo(this.index, this.reason)
      : kind = AbrActionKind.switchTo;

  const AbrAction.reResolve(this.reason)
      : kind = AbrActionKind.reResolve,
        index = null;

  final AbrActionKind kind;
  final int? index;
  final String reason;
}

/// Mirrors `lixh-stream-supervisor` + simple upshift when healthy.
///
/// Candidates are expected ranked like [resolveRoom]: priority asc, bitrate asc
/// (index 0 = safest / lowest bitrate).
class AbrSupervisor {
  AbrSupervisor({
    required List<StreamPick> candidates,
    this.stallThresholdMs = 1200,
    this.hardStallMs = 3000,
    this.maxStalls = 2,
    this.healthyTicksForUpshift = 20,
    this.upshiftLagMs = 400,
  }) : _candidates = List<StreamPick>.from(candidates);

  final List<StreamPick> _candidates;
  final int stallThresholdMs;
  final int hardStallMs;
  final int maxStalls;
  final int healthyTicksForUpshift;
  final int upshiftLagMs;

  int? _current;
  final Set<int> _failed = {};
  int _consecutiveStalls = 0;
  int _healthyTicks = 0;
  int _lastProgress = 0;
  bool _hasProgress = false;
  DateTime? _lastProgressAt;
  DateTime? _lastObserveAt;

  List<StreamPick> get candidates => List.unmodifiable(_candidates);
  int? get currentIndex => _current;
  StreamPick? get current =>
      _current == null ? null : _candidates[_current!];

  void reset(List<StreamPick> candidates) {
    _candidates
      ..clear()
      ..addAll(candidates);
    _current = null;
    _failed.clear();
    _consecutiveStalls = 0;
    _healthyTicks = 0;
    _lastProgress = 0;
    _hasProgress = false;
    _lastProgressAt = null;
    _lastObserveAt = null;
  }

  void setCurrent(int index) {
    if (index < 0 || index >= _candidates.length) return;
    _current = index;
    _consecutiveStalls = 0;
    _healthyTicks = 0;
    _lastProgress = 0;
    _hasProgress = false;
    _lastProgressAt = null;
    _lastObserveAt = null;
  }

  /// Initial pick: first non-failed (resolver already ranked for low latency).
  int? selectInitial() {
    for (var i = 0; i < _candidates.length; i++) {
      if (!_failed.contains(i)) return i;
    }
    return null;
  }

  /// Observe one stats sample. [progress] = audioFrames + presentOk (or similar).
  /// [lagMs] = effective delay (clock lag + audio queue).
  AbrAction observe({
    required int progress,
    required int lagMs,
    required bool playing,
    DateTime? now,
  }) {
    if (!playing || _candidates.isEmpty) return const AbrAction.keep();
    if (_current == null) {
      return const AbrAction.reResolve('no current candidate');
    }

    final t = now ?? DateTime.now();
    final elapsed = _lastObserveAt == null
        ? 0
        : t.difference(_lastObserveAt!).inMilliseconds.clamp(0, 60000);
    _lastObserveAt = t;

    final progressed = progress > _lastProgress;
    if (progressed) {
      _lastProgress = progress;
      _hasProgress = true;
      _lastProgressAt = t;
      _consecutiveStalls = 0;
    }

    final stalledMs = !_hasProgress
        ? elapsed
        : (_lastProgressAt == null
            ? elapsed
            : t.difference(_lastProgressAt!).inMilliseconds.clamp(0, 60000));

    if (lagMs >= hardStallMs || stalledMs >= hardStallMs) {
      return _failureAction('hard stall lag=$lagMs stalled=${stalledMs}ms');
    }
    if (lagMs >= stallThresholdMs || stalledMs >= stallThresholdMs) {
      _healthyTicks = 0;
      if (!progressed) {
        _consecutiveStalls++;
        if (_consecutiveStalls >= maxStalls) {
          return _failureAction('repeated stall');
        }
      }
      return const AbrAction.keep();
    }

    // Healthy: consider upshift to higher bitrate rung.
    if (lagMs <= upshiftLagMs && progressed) {
      _healthyTicks++;
      if (_healthyTicks >= healthyTicksForUpshift) {
        final next = _current! + 1;
        if (next < _candidates.length && !_failed.contains(next)) {
          _healthyTicks = 0;
          _current = next;
          _consecutiveStalls = 0;
          return AbrAction.switchTo(next, 'upshift bitrate');
        }
      }
    } else {
      _healthyTicks = 0;
    }

    return const AbrAction.keep();
  }

  AbrAction reportFailure(String reason) => _failureAction(reason);

  AbrAction _failureAction(String reason) {
    final cur = _current;
    if (cur != null) _failed.add(cur);

    // Prefer a lower-bitrate rung first, then any unused higher index.
    int? next;
    if (cur != null) {
      for (var i = cur - 1; i >= 0; i--) {
        if (!_failed.contains(i)) {
          next = i;
          break;
        }
      }
    }
    next ??= () {
      for (var i = 0; i < _candidates.length; i++) {
        if (i != cur && !_failed.contains(i)) return i;
      }
      return null;
    }();

    if (next != null) {
      _current = next;
      _consecutiveStalls = 0;
      _healthyTicks = 0;
      _hasProgress = false;
      _lastProgress = 0;
      _lastProgressAt = null;
      _lastObserveAt = null;
      return AbrAction.switchTo(next, reason);
    }
    return AbrAction.reResolve(reason);
  }
}
