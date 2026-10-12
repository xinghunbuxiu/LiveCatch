import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_settings.dart';

Future<AppSettings?> showSettingsSheet(
  BuildContext context, {
  required AppSettings initial,
  required List<String> logs,
  ValueListenable<int>? logsTick,
}) {
  return showModalBottomSheet<AppSettings>(
    context: context,
    isScrollControlled: true,
    backgroundColor: const Color(0xFF121A18),
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
    builder: (ctx) => _SettingsSheet(
      initial: initial,
      logs: logs,
      logsTick: logsTick,
    ),
  );
}

class _SettingsSheet extends StatefulWidget {
  const _SettingsSheet({
    required this.initial,
    required this.logs,
    this.logsTick,
  });

  final AppSettings initial;
  final List<String> logs;
  final ValueListenable<int>? logsTick;

  @override
  State<_SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends State<_SettingsSheet> {
  late AppSettings _draft;

  @override
  void initState() {
    super.initState();
    _draft = widget.initial.copyWith();
  }

  Future<void> _save() async {
    await _draft.save();
    if (!mounted) return;
    Navigator.of(context).pop(_draft);
  }

  void _openLogs() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => _LogViewerPage(
          logs: widget.logs,
          logsTick: widget.logsTick,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final foam = Theme.of(context).colorScheme.onSurface;
    final signal = Theme.of(context).colorScheme.primary;
    final bottom = MediaQuery.paddingOf(context).bottom;
    final logsTile = widget.logsTick == null
        ? _logsListTile(foam, signal, widget.logs.length)
        : ValueListenableBuilder<int>(
            valueListenable: widget.logsTick!,
            builder: (_, __, ___) =>
                _logsListTile(foam, signal, widget.logs.length),
          );

    return Padding(
      padding: EdgeInsets.fromLTRB(16, 14, 16, 16 + bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text(
                '播放配置',
                style: TextStyle(
                  fontFamily: 'Bahnschrift',
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: foam,
                ),
              ),
              const Spacer(),
              IconButton(
                onPressed: () => Navigator.of(context).pop(),
                icon: Icon(Icons.close, color: foam.withValues(alpha: 0.7)),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '保存到本机；延迟立即生效，其余下次开播生效',
            style: TextStyle(fontSize: 12, color: foam.withValues(alpha: 0.45)),
          ),
          const SizedBox(height: 12),
          logsTile,
          const SizedBox(height: 8),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            activeThumbColor: signal,
            title: Text('开播默认开画面', style: TextStyle(color: foam, fontSize: 14)),
            subtitle: Text(
              '关闭则为听播优先',
              style: TextStyle(color: foam.withValues(alpha: 0.45), fontSize: 12),
            ),
            value: _draft.startWithVideo,
            onChanged: (v) => setState(() => _draft.startWithVideo = v),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            activeThumbColor: signal,
            title: Text('自动 ABR', style: TextStyle(color: foam, fontSize: 14)),
            subtitle: Text(
              '默认关闭。开启后卡顿降档/流畅升档，切换会短暂重连',
              style: TextStyle(color: foam.withValues(alpha: 0.45), fontSize: 12),
            ),
            value: _draft.abrEnabled,
            onChanged: (v) => setState(() => _draft.abrEnabled = v),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            activeThumbColor: signal,
            title: Text('优先 FLV', style: TextStyle(color: foam, fontSize: 14)),
            subtitle: Text(
              '有 FLV 时忽略 HLS',
              style: TextStyle(color: foam.withValues(alpha: 0.45), fontSize: 12),
            ),
            value: _draft.preferFlv,
            onChanged: (v) => setState(() => _draft.preferFlv = v),
          ),
          const SizedBox(height: 8),
          Text(
            '延迟档位',
            style: TextStyle(color: foam, fontSize: 14, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final p in LatencyProfile.values)
                ChoiceChip(
                  label: Text(p.label),
                  selected: _draft.latency == p,
                  selectedColor: signal.withValues(alpha: 0.25),
                  labelStyle: TextStyle(
                    color: _draft.latency == p ? signal : foam.withValues(alpha: 0.75),
                    fontSize: 13,
                  ),
                  side: BorderSide(
                    color: _draft.latency == p
                        ? signal.withValues(alpha: 0.7)
                        : foam.withValues(alpha: 0.2),
                  ),
                  shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
                  onSelected: (_) => setState(() => _draft.latency = p),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            _draft.latency.hint,
            style: TextStyle(fontSize: 12, color: foam.withValues(alpha: 0.45)),
          ),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: _save,
            style: FilledButton.styleFrom(
              minimumSize: const Size(0, 44),
              shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
            ),
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }

  Widget _logsListTile(Color foam, Color signal, int count) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(Icons.article_outlined, color: signal),
      title: Text('运行日志', style: TextStyle(color: foam, fontSize: 14)),
      subtitle: Text(
        count == 0 ? '暂无记录' : '共 $count 条 · 点此全屏查看',
        style: TextStyle(color: foam.withValues(alpha: 0.45), fontSize: 12),
      ),
      trailing: Icon(
        Icons.chevron_right,
        color: foam.withValues(alpha: 0.45),
      ),
      onTap: _openLogs,
    );
  }
}

class _LogViewerPage extends StatelessWidget {
  const _LogViewerPage({required this.logs, this.logsTick});

  final List<String> logs;
  final ValueListenable<int>? logsTick;

  Future<void> _copy(BuildContext context) async {
    final text = logs.isEmpty ? '(空)' : logs.join('\n');
    await Clipboard.setData(ClipboardData(text: text));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已复制全部日志'), duration: Duration(seconds: 1)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final foam = Theme.of(context).colorScheme.onSurface;
    final signal = Theme.of(context).colorScheme.primary;
    final body = logsTick == null
        ? _buildBody(foam)
        : ValueListenableBuilder<int>(
            valueListenable: logsTick!,
            builder: (_, __, ___) => _buildBody(foam),
          );

    return Scaffold(
      backgroundColor: const Color(0xFF0B0F0E),
      appBar: AppBar(
        backgroundColor: const Color(0xFF121A18),
        foregroundColor: foam,
        title: Text(
          '运行日志',
          style: TextStyle(
            fontFamily: 'Bahnschrift',
            fontWeight: FontWeight.w700,
            color: foam,
          ),
        ),
        actions: [
          IconButton(
            tooltip: '复制',
            onPressed: () => _copy(context),
            icon: Icon(Icons.copy_all_outlined, color: signal),
          ),
        ],
      ),
      body: body,
    );
  }

  Widget _buildBody(Color foam) {
    if (logs.isEmpty) {
      return Center(
        child: Text(
          '暂无日志',
          style: TextStyle(color: foam.withValues(alpha: 0.45)),
        ),
      );
    }
    return SelectionArea(
      child: Scrollbar(
        child: ListView.builder(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
          itemCount: logs.length,
          itemBuilder: (context, i) {
            final line = logs[i];
            final isErr = line.contains('失败') ||
                line.contains('error') ||
                line.contains('Error') ||
                line.contains('native:');
            return Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(
                line,
                style: TextStyle(
                  fontFamily: 'Consolas',
                  fontSize: 12,
                  height: 1.35,
                  color: isErr
                      ? const Color(0xFFFF8A80)
                      : foam.withValues(alpha: 0.85),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
