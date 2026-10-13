import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lixh_player/lixh_player.dart';

import 'abr_supervisor.dart';
import 'app_settings.dart';
import 'douyin_expand.dart';
import 'live_input.dart';
import 'playback_keepalive.dart';
import 'room_resolve.dart';
import 'settings_sheet.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  PlaybackKeepAlive.bind();
  runApp(const LiveCatchApp());
}

class LiveCatchApp extends StatelessWidget {
  const LiveCatchApp({super.key});

  @override
  Widget build(BuildContext context) {
    const ink = Color(0xFF0B0F0E);
    const foam = Color(0xFFE7F0EC);
    const signal = Color(0xFF3DCF9A);
    return MaterialApp(
      title: 'LiveCatch',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: ink,
        colorScheme: const ColorScheme.dark(
          surface: ink,
          primary: signal,
          onPrimary: Color(0xFF04140E),
          secondary: Color(0xFF8AD9B8),
          onSurface: foam,
        ),
        fontFamily: 'Segoe UI',
        useMaterial3: true,
      ),
      home: const PlayerPage(),
    );
  }
}

class PlayerPage extends StatefulWidget {
  const PlayerPage({super.key});

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  final _player = LixhPlayer();
  final _urlCtrl = TextEditingController();
  late final AnimationController _pulse;

  VideoTextureInfo? _texture;
  String _status = '初始化…';
  String _title = '';
  String _platform = '';
  Timer? _statsTimer;
  bool _busy = false;
  bool _playing = false;
  bool _videoOn = false;
  /// User wants video when foreground; may be suppressed while backgrounded.
  bool _videoDesired = false;
  bool _appInBackground = false;
  String? _headers;
  String? _roomInput;
  int _lastProgress = 0;
  int _stallTicks = 0;
  int _reconnects = 0;
  int _graceTicks = 0;

  int _audioFrames = 0;
  int _presentOk = 0;
  int _lagMs = 0;
  int _audioQueueMs = 0;
  int _bitrateKbps = 0;
  int _videoW = 0;
  int _videoH = 0;
  int _dropped = 0;
  int _lastBytes = 0;
  DateTime? _lastBytesAt;

  AbrSupervisor? _abr;
  bool _abrBusy = false;
  bool _statsInFlight = false;
  String _abrLabel = '';
  /// Bumped on stop/start so in-flight ABR open/play can bail out.
  int _playGen = 0;
  AppSettings _settings = AppSettings();
  final List<String> _logs = <String>[];
  final ValueNotifier<int> _logsTick = ValueNotifier<int>(0);
  String? _lastLoggedNativeErr;
  /// Last clipboard payload we auto-filled (avoid re-applying the same paste).
  String? _lastAutoClipboardRaw;
  /// URL last written by clipboard auto-fill (so we can refresh if user hasn't edited).
  String? _lastAutoFillUrl;

  void _appendLog(String message) {
    final t = DateTime.now();
    final stamp =
        '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}';
    final line = '[$stamp] $message';
    debugPrint('[LiveCatch] $message');
    _logs.add(line);
    if (_logs.length > 400) {
      _logs.removeRange(0, _logs.length - 400);
    }
    _logsTick.value++;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    PlaybackKeepAlive.onStopFromNotification = () {
      _appendLog('通知栏停止');
      _stop();
    };
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2400),
    )..repeat();
    _boot();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Only paused/hidden = real background. inactive fires for sheets/dialogs.
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _enterBackground();
    } else if (state == AppLifecycleState.resumed) {
      _enterForeground();
      // ignore: unawaited_futures
      _maybePasteClipboard();
    }
  }

  /// Pull live URL / Douyin share text from the system clipboard into the field.
  Future<void> _maybePasteClipboard() async {
    if (!mounted || _busy) return;
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final text = data?.text;
      if (text == null || text.trim().isEmpty) return;
      if (!isPasteableLiveClipboard(text)) return;
      if (text == _lastAutoClipboardRaw) return;

      final extracted = extractLiveInput(text);
      if (extracted == null) return;

      final current = _urlCtrl.text.trim();
      if (current.isNotEmpty &&
          current != _lastAutoFillUrl &&
          current != extracted) {
        // User typed a different URL — do not overwrite.
        return;
      }

      _lastAutoClipboardRaw = text;
      var filled = extracted;
      _lastAutoFillUrl = filled;
      _urlCtrl.value = TextEditingValue(
        text: filled,
        selection: TextSelection.collapsed(offset: filled.length),
      );
      _appendLog('剪切板填入: $filled');
      if (mounted) setState(() {});

      // Best-effort: rewrite v.douyin short links to live.douyin.com/{web_rid}.
      if (looksLikeDouyinShortUrl(filled)) {
        try {
          final expanded = await expandDouyinShortUrl(filled);
          if (!mounted || _busy) return;
          // Only update if the field still shows what we just filled.
          if (_urlCtrl.text.trim() != filled) return;
          if (expanded == filled) return;
          _lastAutoFillUrl = expanded;
          _urlCtrl.value = TextEditingValue(
            text: expanded,
            selection: TextSelection.collapsed(offset: expanded.length),
          );
          _appendLog('短链 → $expanded');
          if (mounted) setState(() {});
        } catch (_) {
          // Keep short link; _start() will expand again before resolve.
        }
      }
    } catch (_) {
      // Clipboard may be blocked (Android privacy / empty).
    }
  }

  Future<void> _enterBackground() async {
    if (_appInBackground) return;
    _appInBackground = true;
    if (!_playing) return;
    await PlaybackKeepAlive.start(
      title: _title.isEmpty ? 'LiveCatch' : _title,
      text: '后台听播中',
    );
    // Drop video sink so MediaCodec Surface isn't required while screen-off.
    if (_videoOn) {
      _videoDesired = true;
      try {
        await _player.setVideoEnabled(false);
        if (mounted) setState(() => _videoOn = false);
        _appendLog('后台：切听播保活');
      } catch (e) {
        _appendLog('后台听播: $e');
      }
    }
  }

  Future<void> _enterForeground() async {
    if (!_appInBackground) return;
    _appInBackground = false;
    if (!_playing) {
      await PlaybackKeepAlive.stop();
      return;
    }
    await PlaybackKeepAlive.update(
      title: _title.isEmpty ? 'LiveCatch' : _title,
      text: _videoDesired ? '播放中' : '听播中',
    );
    if (_videoDesired && !_videoOn) {
      try {
        await _player.setVideoEnabled(true);
        if (mounted) {
          setState(() {
            _videoOn = true;
            _graceTicks = 6;
            _status = '画面';
          });
        }
        _appendLog('前台：恢复画面');
      } catch (e) {
        _appendLog('恢复画面: $e');
      }
    }
  }

  Future<void> _syncKeepAlive({required bool playing}) async {
    if (!playing) {
      await PlaybackKeepAlive.stop();
      return;
    }
    await PlaybackKeepAlive.start(
      title: _title.isEmpty ? 'LiveCatch' : _title,
      text: _appInBackground
          ? '后台听播中'
          : (_videoOn ? '播放中' : '听播中'),
    );
  }

  Future<void> _applyLatency({bool? videoOn}) async {
    final on = videoOn ?? _videoOn;
    final (t, m) = _settings.latency.latencyMsFor(videoOn: on);
    await _player.setLatency(targetMs: t, maxMs: m);
  }

  Future<void> _openSettings() async {
    final next = await showSettingsSheet(
      context,
      initial: _settings,
      logs: _logs,
      logsTick: _logsTick,
    );
    if (next == null || !mounted) return;
    setState(() => _settings = next);
    try {
      await _applyLatency();
    } catch (e) {
      _appendLog('setLatency: $e');
    }
  }

  Future<void> _boot() async {
    try {
      _settings = await AppSettings.load();
      final info = await _player.createVideoTexture(width: 1920, height: 1080);
      try {
        // Boot is listen-first until the user opens picture.
        await _applyLatency(videoOn: _settings.startWithVideo);
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        _texture = info;
        _status = '就绪';
      });
      _appendLog('就绪');
      await _maybePasteClipboard();
      // Guard overlapping getStats / reconnect work — otherwise a wedged
      // stop/open on the platform thread freezes the whole UI.
      _statsTimer = Timer.periodic(const Duration(milliseconds: 750), (_) async {
        if (!_playing || _busy || _statsInFlight || _abrBusy) return;
        _statsInFlight = true;
        try {
          final s = await _player.getStats();
          if (!mounted) return;

          final now = DateTime.now();
          var kbps = _bitrateKbps;
          if (_lastBytesAt != null) {
            final dt = now.difference(_lastBytesAt!).inMilliseconds;
            if (dt > 200 && s.bytesRead >= _lastBytes) {
              kbps = (((s.bytesRead - _lastBytes) * 8) / dt).round();
            }
          }
          _lastBytes = s.bytesRead;
          _lastBytesAt = now;

          final progress = s.audioFrames + s.presentOk;
          if (_graceTicks > 0) {
            _graceTicks--;
            _lastProgress = progress;
            _stallTicks = 0;
          } else if (progress > _lastProgress) {
            _lastProgress = progress;
            _stallTicks = 0;
          } else if (_lastProgress > 0) {
            _stallTicks++;
            if (_stallTicks >= 10 && !_abrBusy) {
              final abr = _abr;
              // Even with ABR off: fail over to another candidate before full re-resolve.
              if (abr != null) {
                final action = abr.reportFailure('stall ticks');
                _stallTicks = 0;
                if (action.kind == AbrActionKind.switchTo &&
                    action.index != null) {
                  // ignore: unawaited_futures
                  _switchAbr(action.index!, action.reason);
                  return;
                }
                if (action.kind == AbrActionKind.reResolve &&
                    _roomInput != null &&
                    _reconnects < 3) {
                  _reconnects++;
                  setState(() => _status = '卡顿，重解析 #$_reconnects…');
                  // ignore: unawaited_futures
                  _start();
                  return;
                }
              } else if (_roomInput != null &&
                  !looksLikeDirectStream(_roomInput!) &&
                  _reconnects < 3) {
                _stallTicks = 0;
                _reconnects++;
                setState(() => _status = '卡顿，重连 #$_reconnects…');
                // ignore: unawaited_futures
                _start();
                return;
              }
            }
          }

          // lagMs = clock-drift / chase backlog (NOT absolute live delay).
          // audioQueueMs = app PCM backlog. Do not sum them as end-to-end latency.
          final chaseLag = s.lagMs < 0 ? 0 : s.lagMs;
          final queueMs = s.audioQueueMs < 0 ? 0 : s.audioQueueMs;
          final backlogMs =
              chaseLag > queueMs ? chaseLag : queueMs;

          if (s.lastError.isNotEmpty && s.lastError != _lastLoggedNativeErr) {
            _lastLoggedNativeErr = s.lastError;
            _appendLog('native: ${s.lastError}');
          }
          if (_stallTicks == 4 || (_stallTicks > 0 && _stallTicks % 10 == 0)) {
            _appendLog(
              'stall tick=$_stallTicks a=${s.audioFrames} '
              'p=${s.presentOk} chase=$chaseLag q=$queueMs '
              'br=$kbps drop=${s.droppedFrames}',
            );
          }

          // decodeHw: 0=SW, 1=D3D11, 2=VT, 3=MediaCodec
          // presentMode: 0=none, 1=Surface zero-copy, 2=RGBA
          final hw = switch (s.decodeHw) {
            3 => 'MC',
            > 0 => 'HW',
            0 => 'SW',
            _ => '—',
          };
          final present = switch (s.presentMode) {
            1 => 'Zc',
            2 => 'RGBA',
            _ => '',
          };
          final abrTag = _abrLabel.isEmpty ? '' : ' · $_abrLabel';
          final presentTag = present.isEmpty ? '' : ' · $present';
          final nextStatus =
              (_videoOn ? '画面 · $hw$presentTag' : '听播 · $hw') + abrTag;
          final nextW = s.videoWidth > 0 ? s.videoWidth : _videoW;
          final nextH = s.videoHeight > 0 ? s.videoHeight : _videoH;
          final changed = _audioFrames != s.audioFrames ||
              _presentOk != s.presentOk ||
              _audioQueueMs != queueMs ||
              _lagMs != chaseLag ||
              _bitrateKbps != kbps ||
              _dropped != s.droppedFrames ||
              _videoW != nextW ||
              _videoH != nextH ||
              _status != nextStatus;
          if (changed && mounted) {
            setState(() {
              _audioFrames = s.audioFrames;
              _presentOk = s.presentOk;
              _audioQueueMs = queueMs;
              _lagMs = chaseLag;
              _bitrateKbps = kbps;
              _dropped = s.droppedFrames;
              _videoW = nextW;
              _videoH = nextH;
              _status = nextStatus;
            });
          }

          // ABR only while picture is on — listen path uses only_audio / lean FLV.
          final abr = _abr;
          if (_settings.abrEnabled &&
              abr != null &&
              _videoOn &&
              !_abrBusy &&
              _playing &&
              !_busy &&
              _graceTicks <= 0) {
            final action = abr.observe(
              progress: progress,
              lagMs: backlogMs,
              playing: _playing,
            );
            if (action.kind == AbrActionKind.switchTo &&
                action.index != null) {
              // ignore: unawaited_futures
              _switchAbr(action.index!, action.reason);
            } else if (action.kind == AbrActionKind.reResolve &&
                _roomInput != null &&
                _reconnects < 3) {
              _reconnects++;
              _appendLog('ABR 耗尽，重解析 #$_reconnects');
              if (mounted) setState(() => _status = '重解析 #$_reconnects…');
              // ignore: unawaited_futures
              _start();
            }
          }
        } catch (e) {
          _appendLog('getStats: $e');
        } finally {
          _statsInFlight = false;
        }
      });
    } catch (e) {
      if (!mounted) return;
      final msg = formatResolveError(e);
      _appendLog('监听失败: $msg');
      setState(() => _status = '监听失败');
    }
  }

  Future<void> _switchAbr(int index, String reason) async {
    final abr = _abr;
    if (abr == null || _abrBusy || index < 0 || index >= abr.candidates.length) {
      return;
    }
    final gen = _playGen;
    _abrBusy = true;
    final pick = abr.candidates[index];
    final keepVideo = _videoOn;
    _appendLog(
      'ABR switch ->[$index] ${pick.protocol} ${pick.bitrate}bps ($reason)',
    );
    if (mounted) {
      setState(() {
        _status = 'ABR 切换 ${pick.protocol}…';
        _abrLabel = pick.quality.isNotEmpty
            ? pick.quality
            : (pick.bitrate > 0 ? '${pick.bitrate ~/ 1000}k' : '#$index');
      });
    }
    try {
      if (gen != _playGen) return;
      await _player.stop();
      if (gen != _playGen) return;
      await _player.setVideoEnabled(false);
      if (gen != _playGen) return;
      await _player.open(pick.url, headers: _headers);
      if (gen != _playGen) return;
      await _player.play();
      if (gen != _playGen) return;
      if (keepVideo) await _player.setVideoEnabled(true);
      if (gen != _playGen) return;
      abr.setCurrent(index);
      _lastProgress = 0;
      _stallTicks = 0;
      _graceTicks = 6;
      _lastBytes = 0;
      _lastBytesAt = null;
      if (!mounted) return;
      setState(() {
        _playing = true;
        _videoOn = keepVideo && !_appInBackground;
        _videoDesired = keepVideo;
        _status = keepVideo ? '画面' : '听播中';
      });
      if (keepVideo && _appInBackground) {
        await _player.setVideoEnabled(false);
      }
      // Re-bind chase/PCM to listen vs picture after ABR reopen.
      await _applyLatency(videoOn: _videoOn);
      await _syncKeepAlive(playing: true);
    } catch (e) {
      if (gen != _playGen) return;
      debugPrint('[LiveCatch] ABR switch failed: $e');
      final next = abr.reportFailure('open failed: $e');
      if (next.kind == AbrActionKind.switchTo && next.index != null) {
        _abrBusy = false;
        await _switchAbr(next.index!, next.reason);
        return;
      }
      if (next.kind == AbrActionKind.reResolve &&
          _roomInput != null &&
          _reconnects < 3) {
        _reconnects++;
        _abrBusy = false;
        _appendLog('ABR 失败，重解析: ${formatResolveError(e)}');
        if (mounted) setState(() => _status = 'ABR 失败，重解析…');
        await _start();
        return;
      }
      final msg = formatResolveError(e);
      _appendLog('ABR 失败: $msg');
      await PlaybackKeepAlive.stop();
      if (mounted) {
        setState(() {
          _playing = false;
          _status = isLiveEndedResolveError(e) ? msg : 'ABR 失败：$msg';
        });
      }
    } finally {
      if (gen == _playGen) _abrBusy = false;
    }
  }

  Future<void> _start() async {
    final rawInput = _urlCtrl.text.trim();
    if (rawInput.isEmpty || _busy) return;
    // Douyin share cards → short link; plain room URLs pass through.
    var input = extractLiveInput(rawInput) ?? rawInput;
    if (input != rawInput) {
      _urlCtrl.value = TextEditingValue(
        text: input,
        selection: TextSelection.collapsed(offset: input.length),
      );
      _lastAutoFillUrl = input;
      _appendLog('已提取链接: $input');
    }
    final wantVideo = _settings.startWithVideo;
    final startGen = ++_playGen;
    setState(() {
      _busy = true;
      _playing = false;
      _videoOn = false;
      _videoDesired = false;
      _status = '准备…';
      _title = '';
      _platform = '';
      _bitrateKbps = 0;
      _lagMs = 0;
      _audioQueueMs = 0;
      _videoW = 0;
      _videoH = 0;
      _abrLabel = '';
      _lastLoggedNativeErr = null;
    });

    try {
      if (looksLikeDouyinShortUrl(input)) {
        setState(() => _status = '展开短链…');
        _appendLog('展开短链: $input');
        input = await expandDouyinShortUrl(input);
        _urlCtrl.value = TextEditingValue(
          text: input,
          selection: TextSelection.collapsed(offset: input.length),
        );
        _lastAutoFillUrl = input;
        _appendLog('短链 → $input');
      }

      await PlaybackKeepAlive.stop();
      await _applyLatency(videoOn: false);
      await _player.stop();
      await _player.setVideoEnabled(false);
      _lastProgress = 0;
      _stallTicks = 0;
      _graceTicks = 4;
      _lastBytes = 0;
      _lastBytesAt = null;
      _abr = null;

      final urls = <StreamPick>[];
      String? headers;
      var preferAbrIndex = 0;
      if (!looksLikeDirectStream(input)) {
        _roomInput = input;
        setState(() => _status = '解析直播间…');
        _appendLog('解析: $input');
        var room = await resolveRoom(
          input,
          preferFlv: _settings.preferFlv,
          // Always start listen-first — pick only_audio FLV when CDN offers it.
          preferAudioOnly: true,
        );
        _appendLog(
          '解析成功 ${room.platform} live=${room.isLive} '
          'streams=${room.candidates.length}',
        );
        if (!mounted || startGen != _playGen) return;
        // Listen / ABR-off: stick to lowest bitrate (index 0) — skip TTFB so we
        // don't waste ~1s and accidentally start on 原画 for "snappy CDN".
        // ABR-on: TTFB only seeds the initial index; ladder stays bitrate-asc.
        if (_settings.abrEnabled && room.candidates.length > 1) {
          setState(() => _status = '探测线路…');
          final ranked = await rankCandidatesByProbe(
            room.candidates,
            headerMap: room.headers,
            siteUrl: room.siteUrl,
          );
          if (!mounted || startGen != _playGen) return;
          final bestUrl = ranked.isNotEmpty ? ranked.first.url : '';
          final found = room.candidates.indexWhere((c) => c.url == bestUrl);
          if (found >= 0) preferAbrIndex = found;
          final label = found >= 0 && room.candidates[found].quality.isNotEmpty
              ? room.candidates[found].quality
              : (found >= 0 ? room.candidates[found].protocol : '?');
          _appendLog(
            'TTFB 首选: $label（档位 ${preferAbrIndex + 1}/${room.candidates.length}）',
          );
        } else if (room.candidates.isNotEmpty) {
          final c = room.candidates.first;
          final label = c.quality.isNotEmpty
              ? c.quality
              : (c.bitrate > 0 ? '${c.bitrate ~/ 1000}k' : c.protocol);
          final ao = c.audioOnly ? ' · only_audio' : '';
          _appendLog('听播选源: $label$ao（跳过 TTFB）');
        }
        if (!mounted || startGen != _playGen) return;
        headers = room.ffmpegHeaders;
        _headers = headers;
        setState(() {
          _platform = room.platform;
          _title = room.title.isEmpty ? room.artist : room.title;
          if (_title.isEmpty) _title = room.platform;
        });
        urls.addAll(room.candidates);
      } else {
        _roomInput = null;
        _headers = null;
        setState(() {
          _platform = '直链';
          _title = '直播流';
        });
        urls.add(
          StreamPick(
            url: input,
            format: 'direct',
            quality: 'direct',
            bitrate: 0,
            priority: 0,
          ),
        );
      }

      if (startGen != _playGen) return;
      final abr = AbrSupervisor(candidates: urls);
      _abr = abr;
      Object? lastErr;
      var idx = abr.selectInitial(preferIndex: preferAbrIndex);
      while (idx != null) {
        final pick = urls[idx];
        abr.setCurrent(idx);
        if (!mounted) return;
        setState(() {
          _status = '接入 ${pick.protocol}…';
          _abrLabel = pick.quality.isNotEmpty
              ? pick.quality
              : (pick.bitrate > 0 ? '${pick.bitrate ~/ 1000}k' : '');
        });
        try {
          await _player.stop();
          await _player.setVideoEnabled(false);
          await _player.open(pick.url, headers: headers ?? _headers);
          await _player.play();
          if (wantVideo) {
            await _player.setVideoEnabled(true);
          }
          if (!mounted) return;
          setState(() {
            _playing = true;
            _busy = false;
            _videoOn = wantVideo;
            _videoDesired = wantVideo;
            _status = wantVideo ? '画面' : '听播中';
            _graceTicks = 4;
          });
          await _syncKeepAlive(playing: true);
          return;
        } catch (e) {
          lastErr = e;
          final next = abr.reportFailure('open failed');
          idx = next.kind == AbrActionKind.switchTo ? next.index : null;
        }
      }
      throw lastErr ?? StateError('没有可用的播放源');
    } catch (e) {
      if (!mounted) return;
      final msg = formatResolveError(e);
      final ended = isLiveEndedResolveError(e);
      _appendLog(ended ? '直播结束: $msg' : '失败: $msg');
      await PlaybackKeepAlive.stop();
      if (!mounted) return;
      setState(() {
        _busy = false;
        _playing = false;
        // Surface the real reason in the HUD (was only "失败").
        _status = msg;
      });
      final messenger = ScaffoldMessenger.maybeOf(context);
      messenger?.clearSnackBars();
      messenger?.showSnackBar(
        SnackBar(
          content: Text(ended ? msg : '解析失败：$msg'),
          duration: Duration(seconds: ended ? 5 : 4),
        ),
      );
    }
  }

  Future<void> _stop() async {
    final gen = ++_playGen;
    _reconnects = 0;
    _stallTicks = 0;
    _abrBusy = false;
    _abr = null;
    _videoDesired = false;
    // Paint UI immediately so Stop never looks dead during a wedged open/ABR.
    if (mounted) {
      setState(() {
        _playing = false;
        _busy = false;
        _videoOn = false;
        _abrLabel = '';
        _status = '停止中…';
      });
    }
    try {
      await PlaybackKeepAlive.stop();
      await _player.setVideoEnabled(false);
      await _player.stop();
    } catch (e) {
      _appendLog('停止: ${formatResolveError(e)}');
    }
    if (!mounted || gen != _playGen) return;
    setState(() => _status = '已停止');
  }

  Future<void> _toggleVideo() async {
    if (!_playing || _busy) return;
    final next = !_videoDesired;
    _videoDesired = next;
    debugPrint('[LiveCatch] toggleVideo -> $next (bg=$_appInBackground)');
    // While backgrounded only remember preference; surface stays off.
    if (_appInBackground) {
      if (mounted) {
        setState(() {
          _status = next ? '后台保持听播（回前台开画面）' : '听播中';
        });
      }
      await _syncKeepAlive(playing: true);
      return;
    }
    setState(() {
      _videoOn = next;
      _graceTicks = 6;
      _stallTicks = 0;
      _status = next ? '开启画面…' : '返回听播…';
    });
    try {
      // only_audio CDN has no video — jump to A/V; return listen → prefer only_audio.
      final abr = _abr;
      final cur = abr?.current;
      if (next) {
        if (abr != null && (cur == null || cur.audioOnly)) {
          final ix = abr.candidates.indexWhere((c) => !c.audioOnly);
          if (ix >= 0) {
            await _switchAbr(ix, 'picture needs A/V');
            if (!mounted) return;
            setState(() => _status = '画面');
            await _syncKeepAlive(playing: true);
            return;
          }
        }
      } else if (abr != null && cur != null && !cur.audioOnly) {
        final ix = abr.candidates.indexWhere((c) => c.audioOnly);
        if (ix >= 0) {
          await _switchAbr(ix, 'listen prefers only_audio');
          if (!mounted) return;
          setState(() => _status = '听播中');
          await _syncKeepAlive(playing: true);
          return;
        }
      }
      await _player.setVideoEnabled(next);
      await _applyLatency(videoOn: next);
      debugPrint('[LiveCatch] setVideoEnabled ok ($next)');
    } catch (e, st) {
      debugPrint('[LiveCatch] setVideoEnabled FAILED: $e\n$st');
    }
    if (!mounted) return;
    setState(() {
      _status = next ? '画面' : '听播中';
    });
    await _syncKeepAlive(playing: true);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    PlaybackKeepAlive.onStopFromNotification = null;
    _statsTimer?.cancel();
    _logsTick.dispose();
    _pulse.dispose();
    _urlCtrl.dispose();
    PlaybackKeepAlive.stop();
    _player.disposeVideoTexture();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final foam = Theme.of(context).colorScheme.onSurface;
    final signal = Theme.of(context).colorScheme.primary;
    final aspect = (_videoW > 0 && _videoH > 0) ? _videoW / _videoH : 16 / 9;

    return Scaffold(
      body: AnnotatedRegion<SystemUiOverlayStyle>(
        value: SystemUiOverlayStyle.light,
        child: DecoratedBox(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0xFF121A18), Color(0xFF0B0F0E)],
            ),
          ),
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
              child: Column(
                children: [
                  _Header(
                    status: _status,
                    title: _title,
                    platform: _platform,
                    bitrateKbps: _bitrateKbps,
                    lagMs: _lagMs,
                    cacheMs: _audioQueueMs,
                    resolution: _videoW > 0 ? '$_videoW×$_videoH' : '—',
                    dropped: _dropped,
                    playing: _playing,
                    onSettings: _openSettings,
                  ),
                  const SizedBox(height: 12),
                  Expanded(
                    child: _Stage(
                      aspect: aspect,
                      videoOn: _videoOn && _playing,
                      texture: _texture,
                      pulse: _pulse,
                      playing: _playing,
                      title: _title,
                      audioFrames: _audioFrames,
                      presentOk: _presentOk,
                      onToggleVideo: _playing ? _toggleVideo : null,
                    ),
                  ),
                  const SizedBox(height: 12),
                  _Dock(
                    controller: _urlCtrl,
                    busy: _busy,
                    playing: _playing,
                    videoOn: _videoOn,
                    startWithVideo: _settings.startWithVideo,
                    signal: signal,
                    foam: foam,
                    onStart: _start,
                    onStop: _stop,
                    onToggleVideo: _toggleVideo,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.status,
    required this.title,
    required this.platform,
    required this.bitrateKbps,
    required this.lagMs,
    required this.cacheMs,
    required this.resolution,
    required this.dropped,
    required this.playing,
    required this.onSettings,
  });

  final String status;
  final String title;
  final String platform;
  final int bitrateKbps;
  final int lagMs;
  final int cacheMs;
  final String resolution;
  final int dropped;
  final bool playing;
  final VoidCallback onSettings;

  String get _speed {
    if (bitrateKbps <= 0) return '—';
    if (bitrateKbps >= 1000) {
      return '${(bitrateKbps / 1000).toStringAsFixed(1)}Mbps';
    }
    return '${bitrateKbps}kbps';
  }

  String get _logLine {
    final parts = <String>[
      if (platform.isNotEmpty) platform,
      if (status.isNotEmpty) status,
      _speed,
      '追${lagMs.clamp(0, 99999)}ms',
      '缓${cacheMs.clamp(0, 99999)}ms',
      if (resolution != '—') resolution,
      if (dropped > 0) '丢$dropped',
    ];
    return parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final foam = Theme.of(context).colorScheme.onSurface;
    final signal = Theme.of(context).colorScheme.primary;
    final roomName =
        (title.isNotEmpty && title != 'LiveCatch') ? title.trim() : '';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text(
              'LiveCatch',
              style: TextStyle(
                fontFamily: 'Bahnschrift',
                fontSize: 22,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.4,
                color: foam,
              ),
            ),
            if (roomName.isNotEmpty) ...[
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  roomName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: foam.withValues(alpha: 0.88),
                  ),
                ),
              ),
            ] else
              const Spacer(),
            const SizedBox(width: 8),
            Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(
                color: playing ? signal : foam.withValues(alpha: 0.25),
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 4),
            IconButton(
              tooltip: '配置',
              onPressed: onSettings,
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
              icon: Icon(
                Icons.tune,
                size: 20,
                color: foam.withValues(alpha: 0.7),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          _logLine,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 12,
            fontFeatures: const [FontFeature.tabularFigures()],
            color: foam.withValues(alpha: 0.55),
          ),
        ),
      ],
    );
  }
}

class _Stage extends StatelessWidget {
  const _Stage({
    required this.aspect,
    required this.videoOn,
    required this.texture,
    required this.pulse,
    required this.playing,
    required this.title,
    required this.audioFrames,
    required this.presentOk,
    required this.onToggleVideo,
  });

  final double aspect;
  final bool videoOn;
  final VideoTextureInfo? texture;
  final AnimationController pulse;
  final bool playing;
  final String title;
  final int audioFrames;
  final int presentOk;
  final VoidCallback? onToggleVideo;

  @override
  Widget build(BuildContext context) {
    final foam = Theme.of(context).colorScheme.onSurface;
    final signal = Theme.of(context).colorScheme.primary;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFF050708),
        border: Border.all(color: foam.withValues(alpha: 0.1)),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // Fit stream aspect into stage (portrait window + landscape video OK).
          final maxW = constraints.maxWidth;
          final maxH = constraints.maxHeight;
          var viewW = maxW;
          var viewH = viewW / aspect;
          if (viewH > maxH) {
            viewH = maxH;
            viewW = viewH * aspect;
          }

          return Stack(
            fit: StackFit.expand,
            children: [
              // Keep Texture mounted — remounting it under Impeller/GLES
              // was causing EGL Context Lost and process death.
              if (texture != null)
                Visibility(
                  visible: videoOn,
                  maintainState: true,
                  maintainAnimation: true,
                  maintainSize: false,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: onToggleVideo,
                    child: Center(
                      child: SizedBox(
                        width: viewW,
                        height: viewH,
                        child: Texture(textureId: texture!.textureId),
                      ),
                    ),
                  ),
                ),
              if (!videoOn)
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: playing ? onToggleVideo : null,
                  child: _ListenPane(
                    pulse: pulse,
                    playing: playing,
                    title: title,
                    audioFrames: audioFrames,
                    signal: signal,
                    foam: foam,
                  ),
                ),
              if (playing)
                Positioned(
                  right: 12,
                  bottom: 12,
                  child: Material(
                    color: Colors.black.withValues(alpha: 0.55),
                    child: InkWell(
                      onTap: onToggleVideo,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 10,
                        ),
                        child: Text(
                          videoOn
                              ? (presentOk > 0 ? '返回听播' : '等待首帧…')
                              : '显示画面',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: signal,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _ListenPane extends StatelessWidget {
  const _ListenPane({
    required this.pulse,
    required this.playing,
    required this.title,
    required this.audioFrames,
    required this.signal,
    required this.foam,
  });

  final AnimationController pulse;
  final bool playing;
  final String title;
  final int audioFrames;
  final Color signal;
  final Color foam;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: pulse,
      builder: (context, _) {
        final t = pulse.value;
        final beat =
            playing ? 0.9 + 0.1 * math.sin(audioFrames * 0.4) : 0.75;
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 160,
                height: 160,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    for (var i = 0; i < 3; i++)
                      Transform.scale(
                        scale: beat * (1 + ((t + i * 0.2) % 1.0) * 0.45),
                        child: Container(
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: signal.withValues(
                                alpha: playing ? 0.28 - i * 0.06 : 0.1,
                              ),
                            ),
                          ),
                        ),
                      ),
                    Container(
                      width: 84,
                      height: 84,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(color: signal, width: 1.4),
                        color: signal.withValues(alpha: playing ? 0.14 : 0.06),
                      ),
                      child: Icon(
                        playing
                            ? Icons.graphic_eq_rounded
                            : Icons.headphones_rounded,
                        color: signal,
                        size: 34,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 18),
              Text(
                playing
                    ? (title.isEmpty ? '正在听播' : title)
                    : '输入地址后开始听播',
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 15,
                  color: foam.withValues(alpha: 0.78),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                playing ? '点击画面或按钮可返回听播' : '默认只出声音，点这里或点「开画面」',
                style: TextStyle(
                  fontSize: 12,
                  color: foam.withValues(alpha: 0.4),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _Dock extends StatelessWidget {
  const _Dock({
    required this.controller,
    required this.busy,
    required this.playing,
    required this.videoOn,
    required this.startWithVideo,
    required this.signal,
    required this.foam,
    required this.onStart,
    required this.onStop,
    required this.onToggleVideo,
  });

  final TextEditingController controller;
  final bool busy;
  final bool playing;
  final bool videoOn;
  final bool startWithVideo;
  final Color signal;
  final Color foam;
  final VoidCallback onStart;
  final VoidCallback onStop;
  final VoidCallback onToggleVideo;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: controller,
          style: const TextStyle(fontSize: 13.5),
          cursorColor: signal,
          decoration: InputDecoration(
            hintText: '直播间 / 抖音分享口令 / m3u8·flv',
            hintStyle: TextStyle(color: foam.withValues(alpha: 0.35)),
            filled: true,
            fillColor: Colors.white.withValues(alpha: 0.04),
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 12,
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.zero,
              borderSide: BorderSide(color: foam.withValues(alpha: 0.14)),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.zero,
              borderSide: BorderSide(color: signal.withValues(alpha: 0.7)),
            ),
          ),
          onSubmitted: (_) => onStart(),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: FilledButton(
                onPressed: (busy || playing) ? null : onStart,
                style: FilledButton.styleFrom(
                  minimumSize: const Size(0, 44),
                  shape: const RoundedRectangleBorder(
                    borderRadius: BorderRadius.zero,
                  ),
                ),
                child: Text(
                  busy
                      ? '接入中…'
                      : (startWithVideo ? '开始播放' : '开始听播'),
                ),
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              height: 44,
              child: OutlinedButton(
                onPressed: (playing || busy) ? onStop : null,
                style: OutlinedButton.styleFrom(
                  shape: const RoundedRectangleBorder(
                    borderRadius: BorderRadius.zero,
                  ),
                  side: BorderSide(color: foam.withValues(alpha: 0.28)),
                ),
                child: const Text('停止'),
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              height: 44,
              child: OutlinedButton(
                onPressed: playing ? onToggleVideo : null,
                style: OutlinedButton.styleFrom(
                  foregroundColor: signal,
                  shape: const RoundedRectangleBorder(
                    borderRadius: BorderRadius.zero,
                  ),
                  side: BorderSide(color: signal.withValues(alpha: 0.55)),
                ),
                child: Text(videoOn ? '关画面' : '开画面'),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
