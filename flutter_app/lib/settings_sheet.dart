import 'package:flutter/material.dart';

import 'app_settings.dart';

Future<AppSettings?> showSettingsSheet(
  BuildContext context, {
  required AppSettings initial,
}) {
  return showModalBottomSheet<AppSettings>(
    context: context,
    isScrollControlled: true,
    backgroundColor: const Color(0xFF121A18),
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
    builder: (ctx) => _SettingsSheet(initial: initial),
  );
}

class _SettingsSheet extends StatefulWidget {
  const _SettingsSheet({required this.initial});

  final AppSettings initial;

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
          const SizedBox(height: 16),
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
