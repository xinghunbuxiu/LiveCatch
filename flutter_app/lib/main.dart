import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lixh_player/lixh_player.dart';

import 'abr_supervisor.dart';
import 'room_resolve.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
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
    with SingleTickerProviderStateMixin {
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
  String _abrLabel = '';

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2400),
    )..repeat();
    _boot();
  }

  Future<void> _boot() async {
    try {
      final info = await _player.createVideoTexture(width: 1920, height: 1080);
      if (!mounted) return;
      setState(() {
        _texture = info;
        _status = '就绪';
      });
      _statsTimer = Timer.periodic(const Duration(milliseconds: 500), (_) async {
        if (!_playing || _busy) return;
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

          final effLag = () {
            var lag = s.lagMs > 0 ? s.lagMs : s.audioQueueMs;
            if (s.lagMs > 0 && s.audioQueueMs > 0) {
              lag = s.lagMs + s.audioQueueMs;
            }
            return lag;
          }();

          setState(() {
            _audioFrames = s.audioFrames;
            _presentOk = s.presentOk;
            // Effective delay: clock lag + PCM queue (lag alone is often 0 after re-anchor).
            _audioQueueMs = s.audioQueueMs;
            _lagMs = effLag;
            _bitrateKbps = kbps;
            _dropped = s.droppedFrames;
            if (s.videoWidth > 0 && s.videoHeight > 0) {
              _videoW = s.videoWidth;
              _videoH = s.videoHeight;
            }
            // decodeHw: 0=SW, 1=D3D11, 2=VT, 3=MediaCodec
            final hw = s.decodeHw > 0 ? 'HW' : (s.decodeHw == 0 ? 'SW' : '—');
            final abr = _abrLabel.isEmpty ? '' : ' · $_abrLabel';
            _status = (_videoOn ? '画面 · $hw' : '听播 · $hw') + abr;
            if (s.lastError.isNotEmpty) {
              _status = s.lastError;
              debugPrint('[LiveCatch] native error: ${s.lastError}');
            }
          });
          if (_stallTicks >= 4) {
            debugPrint(
              '[LiveCatch] stall tick=$_stallTicks a=${s.audioFrames} '
              'p=${s.presentOk} lag=${s.lagMs} q=${s.audioQueueMs} '
              'br=$kbps drop=${s.droppedFrames}',
            );
          }

          // ABR / candidate switch (room resolve only).
          final abr = _abr;
          if (abr != null &&
              !_abrBusy &&
              _playing &&
              !_busy &&
              _graceTicks <= 0) {
            final action = abr.observe(
              progress: progress,
              lagMs: effLag,
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
              setState(() => _status = 'ABR 耗尽，重解析 #$_reconnects…');
              // ignore: unawaited_futures
              _start();
            }
          }
        } catch (e) {
          debugPrint('[LiveCatch] getStats error: $e');
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = '创建失败: $e');
    }
  }

  Future<void> _switchAbr(int index, String reason) async {
    final abr = _abr;
    if (abr == null || _abrBusy || index < 0 || index >= abr.candidates.length) {
      return;
    }
    _abrBusy = true;
    final pick = abr.candidates[index];
    final keepVideo = _videoOn;
    debugPrint('[LiveCatch] ABR switch ->[$index] ${pick.protocol} '
        '${pick.bitrate}bps ($reason)');
    if (mounted) {
      setState(() {
        _status = 'ABR 切换 ${pick.protocol}…';
        _abrLabel = pick.quality.isNotEmpty
            ? pick.quality
            : (pick.bitrate > 0 ? '${pick.bitrate ~/ 1000}k' : '#$index');
      });
    }
    try {
      await _player.stop();
      await _player.setVideoEnabled(false);
      await _player.open(pick.url, headers: _headers);
      await _player.play();
      if (keepVideo) await _player.setVideoEnabled(true);
      abr.setCurrent(index);
      _lastProgress = 0;
      _stallTicks = 0;
      _graceTicks = 6;
      _lastBytes = 0;
      _lastBytesAt = null;
      if (!mounted) return;
      setState(() {
        _playing = true;
        _videoOn = keepVideo;
        _status = keepVideo ? '画面' : '听播中';
      });
    } catch (e) {
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
        if (mounted) setState(() => _status = 'ABR 失败，重解析…');
        await _start();
        return;
      }
      if (mounted) {
        setState(() {
          _playing = false;
          _status = 'ABR 失败: $e';
        });
      }
    } finally {
      _abrBusy = false;
    }
  }

  Future<void> _start() async {
    final input = _urlCtrl.text.trim();
    if (input.isEmpty || _busy) return;
    setState(() {
      _busy = true;
      _playing = false;
      _videoOn = false;
      _status = '准备…';
      _title = '';
      _platform = '';
      _bitrateKbps = 0;
      _lagMs = 0;
      _audioQueueMs = 0;
      _videoW = 0;
      _videoH = 0;
      _abrLabel = '';
    });

    try {
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
      if (!looksLikeDirectStream(input)) {
        _roomInput = input;
        setState(() => _status = '解析直播间…');
        final room = await resolveRoom(input);
        if (!mounted) return;
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

      final abr = AbrSupervisor(candidates: urls);
      _abr = abr;
      Object? lastErr;
      var idx = abr.selectInitial();
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
          if (!mounted) return;
          setState(() {
            _playing = true;
            _busy = false;
            _videoOn = false;
            _status = '听播中';
            _graceTicks = 4;
          });
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
      setState(() {
        _busy = false;
        _playing = false;
        _status = '失败: $e';
      });
    }
  }

  Future<void> _stop() async {
    _reconnects = 0;
    _stallTicks = 0;
    _abrBusy = false;
    _abr = null;
    await _player.setVideoEnabled(false);
    await _player.stop();
    if (!mounted) return;
    setState(() {
      _playing = false;
      _busy = false;
      _videoOn = false;
      _abrLabel = '';
      _status = '已停止';
    });
  }

  Future<void> _toggleVideo() async {
    if (!_playing || _busy) return;
    final next = !_videoOn;
    debugPrint('[LiveCatch] toggleVideo -> $next');
    setState(() {
      _videoOn = next;
      _graceTicks = 6;
      _stallTicks = 0;
      _status = next ? '开启画面…' : '返回听播…';
    });
    try {
      await _player.setVideoEnabled(next);
      debugPrint('[LiveCatch] setVideoEnabled ok ($next)');
    } catch (e, st) {
      debugPrint('[LiveCatch] setVideoEnabled FAILED: $e\n$st');
    }
    if (!mounted) return;
    setState(() {
      _status = next ? '画面' : '听播中';
    });
  }

  @override
  void dispose() {
    _statsTimer?.cancel();
    _pulse.dispose();
    _urlCtrl.dispose();
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
                    title: _playing ? _title : 'LiveCatch',
                    platform: _platform,
                    bitrateKbps: _bitrateKbps,
                    lagMs: _lagMs,
                    cacheMs: _audioQueueMs,
                    resolution: _videoW > 0 ? '${_videoW}×$_videoH' : '—',
                    dropped: _dropped,
                    playing: _playing,
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

  @override
  Widget build(BuildContext context) {
    final foam = Theme.of(context).colorScheme.onSurface;
    final signal = Theme.of(context).colorScheme.primary;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
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
                  const SizedBox(width: 10),
                  Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      color: playing ? signal : foam.withValues(alpha: 0.25),
                      shape: BoxShape.circle,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                [
                  if (platform.isNotEmpty) platform,
                  if (title.isNotEmpty && title != 'LiveCatch') title,
                  status,
                ].where((e) => e.trim().isNotEmpty).join(' · '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  color: foam.withValues(alpha: 0.55),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        _HudCard(
          bitrateKbps: bitrateKbps,
          lagMs: lagMs,
          cacheMs: cacheMs,
          resolution: resolution,
          dropped: dropped,
        ),
      ],
    );
  }
}

class _HudCard extends StatelessWidget {
  const _HudCard({
    required this.bitrateKbps,
    required this.lagMs,
    required this.cacheMs,
    required this.resolution,
    required this.dropped,
  });

  final int bitrateKbps;
  final int lagMs;
  final int cacheMs;
  final String resolution;
  final int dropped;

  String get _speed {
    if (bitrateKbps <= 0) return '—';
    if (bitrateKbps >= 1000) {
      return '${(bitrateKbps / 1000).toStringAsFixed(1)} Mbps';
    }
    return '$bitrateKbps kbps';
  }

  @override
  Widget build(BuildContext context) {
    final foam = Theme.of(context).colorScheme.onSurface;
    return Container(
      constraints: const BoxConstraints(minWidth: 168),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.35),
        border: Border.all(color: foam.withValues(alpha: 0.12)),
      ),
      child: DefaultTextStyle(
        style: TextStyle(
          fontSize: 11,
          height: 1.45,
          fontFeatures: const [FontFeature.tabularFigures()],
          color: foam.withValues(alpha: 0.82),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            _HudLine(label: '网速', value: _speed),
            _HudLine(label: '延时', value: '${lagMs.clamp(0, 99999)} ms'),
            _HudLine(label: '缓存', value: '${cacheMs.clamp(0, 99999)} ms'),
            _HudLine(label: '画质', value: resolution),
            if (dropped > 0) _HudLine(label: '丢帧', value: '$dropped'),
          ],
        ),
      ),
    );
  }
}

class _HudLine extends StatelessWidget {
  const _HudLine({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.42),
          ),
        ),
        const SizedBox(width: 10),
        Text(value),
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
            hintText: '直播间地址 或 m3u8 / flv 直链',
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
                child: Text(busy ? '接入中…' : '开始听播'),
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
