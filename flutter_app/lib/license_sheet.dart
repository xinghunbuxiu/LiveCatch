import 'package:flutter/material.dart';

import 'license_api.dart';
import 'license_session.dart';
import 'rewardplay_config.dart';

Future<LicenseSession?> showLicenseSheet(
  BuildContext context, {
  required LicenseSession session,
  LicenseApi? api,
}) {
  return showModalBottomSheet<LicenseSession>(
    context: context,
    isScrollControlled: true,
    backgroundColor: const Color(0xFF121A18),
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
    builder: (ctx) => _LicenseSheet(
      initial: session,
      api: api ?? LicenseApi(),
    ),
  );
}

class _LicenseSheet extends StatefulWidget {
  const _LicenseSheet({
    required this.initial,
    required this.api,
  });

  final LicenseSession initial;
  final LicenseApi api;

  @override
  State<_LicenseSheet> createState() => _LicenseSheetState();
}

class _LicenseSheetState extends State<_LicenseSheet> {
  late LicenseSession _session;
  late final TextEditingController _codeCtrl;
  LicenseIntegrationStatus? _status;
  LicenseCheckoutContext? _ctx;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _session = widget.initial;
    _codeCtrl = TextEditingController(text: _session.code ?? '');
    _refreshMeta();
  }

  @override
  void dispose() {
    _codeCtrl.dispose();
    super.dispose();
  }

  Future<void> _refreshMeta() async {
    setState(() {
      _error = null;
    });
    try {
      final status = widget.api.hasToken
          ? await widget.api.integrationStatus()
          : null;
      final ctx = await widget.api.checkoutContext();
      if (!mounted) return;
      setState(() {
        _status = status;
        _ctx = ctx;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    }
  }

  Future<void> _activate() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final next = await _session.activate(widget.api, _codeCtrl.text);
      if (!mounted) return;
      setState(() => _session = next);
      Navigator.of(context).pop(next);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _heartbeat() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final next = await _session.heartbeat(widget.api);
      if (!mounted) return;
      setState(() => _session = next);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _unbind() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A2220),
        title: const Text('解绑本机？'),
        content: const Text('解绑后需重新输入授权码才能使用权益功能。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('解绑'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final next = await _session.unbind(widget.api);
      if (!mounted) return;
      setState(() {
        _session = next;
        _codeCtrl.clear();
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final foam = Theme.of(context).colorScheme.onSurface;
    final signal = Theme.of(context).colorScheme.primary;
    final bottom = MediaQuery.paddingOf(context).bottom;
    final ready = _status?.ready == true;
    final openApi = _status?.openApiEnabled == true;
    final licenseOn = _status?.licenseEnabled == true;

    return Padding(
      padding: EdgeInsets.fromLTRB(16, 14, 16, 16 + bottom),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Text(
                  '权益 / 授权',
                  style: TextStyle(
                    fontFamily: 'Bahnschrift',
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: foam,
                  ),
                ),
                const Spacer(),
                IconButton(
                  onPressed: () => Navigator.of(context).pop(_session),
                  icon: Icon(Icons.close, color: foam.withValues(alpha: 0.7)),
                ),
              ],
            ),
            Text(
              '项目 $kRewardPlayProjectCode'
              '${_ctx != null ? ' · ${_ctx!.projectName}' : ''}',
              style: TextStyle(fontSize: 12, color: foam.withValues(alpha: 0.45)),
            ),
            const SizedBox(height: 12),
            _MetaChip(
              foam: foam,
              signal: signal,
              label: 'License',
              ok: licenseOn,
            ),
            const SizedBox(height: 6),
            _MetaChip(
              foam: foam,
              signal: signal,
              label: 'Open API',
              ok: openApi,
            ),
            const SizedBox(height: 6),
            _MetaChip(
              foam: foam,
              signal: signal,
              label: '就绪',
              ok: ready,
            ),
            if (!widget.api.hasToken) ...[
              const SizedBox(height: 10),
              Text(
                '未注入 Integration Token。构建时加 '
                '--dart-define=REWARDPLAY_INTEGRATION_TOKEN=rpt_…',
                style: TextStyle(fontSize: 12, color: Colors.orange.shade200),
              ),
            ],
            if (_status != null && !ready) ...[
              const SizedBox(height: 10),
              Text(
                '后台尚未同时启用 License + Open API，激活会失败。请在 RewardPlay 项目中心打开开关。',
                style: TextStyle(fontSize: 12, color: foam.withValues(alpha: 0.55)),
              ),
            ],
            const SizedBox(height: 14),
            Text(
              '设备 ID',
              style: TextStyle(color: foam, fontSize: 13, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            SelectableText(
              _session.deviceId,
              style: TextStyle(
                fontSize: 12,
                fontFeatures: const [FontFeature.tabularFigures()],
                color: foam.withValues(alpha: 0.65),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _codeCtrl,
              enabled: !_busy,
              style: TextStyle(color: foam),
              decoration: InputDecoration(
                labelText: '授权码',
                labelStyle: TextStyle(color: foam.withValues(alpha: 0.55)),
                hintText: '粘贴平台签发的注册码',
                hintStyle: TextStyle(color: foam.withValues(alpha: 0.3)),
                border: const OutlineInputBorder(borderRadius: BorderRadius.zero),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.zero,
                  borderSide: BorderSide(color: foam.withValues(alpha: 0.2)),
                ),
              ),
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _activate(),
            ),
            if (_session.active) ...[
              const SizedBox(height: 8),
              Text(
                '状态：已激活'
                '${_session.lastHeartbeatAt != null ? ' · 心跳 ${_fmt(_session.lastHeartbeatAt!)}' : ''}',
                style: TextStyle(fontSize: 12, color: signal),
              ),
            ],
            if (_session.lastMessage != null && _session.lastMessage!.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                _session.lastMessage!,
                style: TextStyle(fontSize: 12, color: foam.withValues(alpha: 0.55)),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                style: TextStyle(fontSize: 12, color: Colors.red.shade300),
              ),
            ],
            const SizedBox(height: 14),
            FilledButton(
              onPressed: _busy ? null : _activate,
              style: FilledButton.styleFrom(
                minimumSize: const Size(0, 44),
                shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
              ),
              child: Text(_busy ? '处理中…' : (_session.active ? '重新激活' : '激活')),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _busy || !_session.hasCode ? null : _heartbeat,
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(0, 40),
                      shape: const RoundedRectangleBorder(
                        borderRadius: BorderRadius.zero,
                      ),
                    ),
                    child: const Text('心跳检查'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton(
                    onPressed: _busy || !_session.hasCode ? null : _unbind,
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(0, 40),
                      shape: const RoundedRectangleBorder(
                        borderRadius: BorderRadius.zero,
                      ),
                    ),
                    child: const Text('解绑本机'),
                  ),
                ),
              ],
            ),
            if (_ctx != null && _ctx!.packages.isNotEmpty) ...[
              const SizedBox(height: 16),
              Text(
                '套餐（购码走支付，当前 '
                '${_ctx!.paymentReady ? '支付已就绪' : '支付未启用'}）',
                style: TextStyle(
                  color: foam,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 6),
              for (final p in _ctx!.packages)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(
                    '${p.packageName} · ${_yuan(p.priceFen)}'
                    '${p.durationDays != null ? ' · ${p.durationDays}天' : ' · 永久'}',
                    style: TextStyle(
                      fontSize: 12,
                      color: foam.withValues(alpha: 0.55),
                    ),
                  ),
                ),
              if (_ctx!.paymentHint != null && _ctx!.paymentHint!.isNotEmpty)
                Text(
                  _ctx!.paymentHint!,
                  style: TextStyle(
                    fontSize: 11,
                    color: foam.withValues(alpha: 0.4),
                  ),
                ),
            ],
            const SizedBox(height: 8),
            TextButton(
              onPressed: _busy ? null : _refreshMeta,
              child: const Text('刷新状态'),
            ),
          ],
        ),
      ),
    );
  }

  static String _yuan(int fen) => '¥${(fen / 100).toStringAsFixed(2)}';

  static String _fmt(DateTime t) {
    final l = t.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(l.hour)}:${two(l.minute)}:${two(l.second)}';
  }
}

class _MetaChip extends StatelessWidget {
  const _MetaChip({
    required this.foam,
    required this.signal,
    required this.label,
    required this.ok,
  });

  final Color foam;
  final Color signal;
  final String label;
  final bool ok;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(
          ok ? Icons.check_circle : Icons.cancel,
          size: 16,
          color: ok ? signal : foam.withValues(alpha: 0.35),
        ),
        const SizedBox(width: 6),
        Text(
          '$label：${ok ? '已开启' : '未开启'}',
          style: TextStyle(fontSize: 13, color: foam.withValues(alpha: 0.75)),
        ),
      ],
    );
  }
}
