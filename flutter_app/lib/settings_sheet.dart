import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_settings.dart';

Future<AppSettings?> showSettingsSheet(
  BuildContext context, {
  required AppSettings initial,
  List<String> logs = const [],
}) {
  return showModalBottomSheet<AppSettings>(
    context: context,
    isScrollControlled: true,
    backgroundColor: const Color(0xFF121A18),
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
    builder: (ctx) => _SettingsSheet(initial: initial, logs: logs),
  );
}

class _SettingsSheet extends StatefulWidget {
  const _SettingsSheet({required this.initial, required this.logs});

  final AppSettings initial;
  final List<String> logs;

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
        builder: (_) => _LogViewerPage(logs: widget.logs),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final foam = Theme.of(context).colorScheme.onSurface;
    final signal = Theme.of(context).colorScheme.primary;
    final bottom = MediaQuery.paddingOf(context).bottom;

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
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.article_outlined, color: signal),
            title: Text('运行日志', style: TextStyle(color: foam, fontSize: 14)),
            subtitle: Text(
              widget.logs.isEmpty
                  ? '暂无记录'
                  : '共 ${widget.logs.length} 条 · 点此全屏查看',
              style: TextStyle(color: foam.withValues(alpha: 0.45), fontSize: 12),
            ),
            trailing: Icon(
              Icons.chevron_right,
              color: foam.withValues(alpha: 0.45),
            ),
            onTap: _openLogs,
          ),
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
              '卡顿时切换码率/线路',
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
}

class _LogViewerPage extends StatelessWidget {
  const _LogViewerPage({required this.logs});

  final List<String> logs;

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
      body: logs.isEmpty
          ? Center(
              child: Text(
                '暂无日志',
                style: TextStyle(color: foam.withValues(alpha: 0.45)),
              ),
            )
          : SelectionArea(
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
            ),
    );
  }
}
