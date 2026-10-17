import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'license_api.dart';
import 'license_gate.dart';
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
  LicenseCheckoutContext? _ctx;
  String? _error;
  String? _hint;
  bool _busy = false;
  bool _loadingPlans = true;

  @override
  void initState() {
    super.initState();
    _session = widget.initial;
    _codeCtrl = TextEditingController(text: _session.code ?? '');
    _loadPackages();
  }

  @override
  void dispose() {
    _codeCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadPackages() async {
    setState(() {
      _loadingPlans = true;
      _error = null;
    });
    try {
      final ctx = await widget.api.checkoutContext();
      if (!mounted) return;
      setState(() {
        _ctx = ctx;
        _loadingPlans = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingPlans = false;
        _hint = '套餐暂时加载失败，仍可直接输入注册码激活';
      });
    }
  }

  Future<void> _activate() async {
    final code = _codeCtrl.text.trim();
    if (code.isEmpty) {
      setState(() => _error = '请输入注册码');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final next = await _session.activate(widget.api, code);
      if (!mounted) return;
      setState(() => _session = next);
      Navigator.of(context).pop(next);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = _friendlyError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _unbind() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A2220),
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
        title: const Text('解除本机绑定？'),
        content: const Text('解绑后本机将无法继续使用权益，需要重新输入注册码。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确认解绑'),
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
      setState(() => _error = _friendlyError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openBuy({bool renew = false}) async {
    final url = renew ? kRewardPlayRenewalUrl : kRewardPlayCheckoutUrl;
    try {
      await openLicenseWeb(url);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = _friendlyError(e));
    }
  }

  Future<void> _copyDeviceId() async {
    await Clipboard.setData(ClipboardData(text: _session.deviceId));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('本机编号已复制'), duration: Duration(seconds: 2)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final foam = Theme.of(context).colorScheme.onSurface;
    final signal = Theme.of(context).colorScheme.primary;
    final bottom = MediaQuery.paddingOf(context).bottom;
    final packages = _ctx?.packages ?? const <LicensePackage>[];
    final projectName = (_ctx?.projectName.trim().isNotEmpty == true)
        ? _ctx!.projectName
        : 'LiveCatch';
    final canPay = _ctx?.paymentReady == true;

    return Padding(
      padding: EdgeInsets.fromLTRB(16, 14, 16, 16 + bottom),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    _session.active ? '我的权益' : '激活权益',
                    style: TextStyle(
                      fontFamily: 'Bahnschrift',
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: foam,
                    ),
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.of(context).pop(_session),
                  icon: Icon(Icons.close, color: foam.withValues(alpha: 0.7)),
                ),
              ],
            ),
            Text(
              _session.active
                  ? '已开通 · 可解析并收听直播'
                  : '输入注册码即可开通，或先选套餐购买',
              style: TextStyle(fontSize: 13, color: foam.withValues(alpha: 0.55)),
            ),
            const SizedBox(height: 16),
            if (_session.active) ...[
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  border: Border.all(color: signal.withValues(alpha: 0.35)),
                ),
                child: Row(
                  children: [
                    Icon(Icons.verified, color: signal, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '权益有效'
                        '${_session.lastMessage != null && _session.lastMessage!.isNotEmpty ? ' · ${_session.lastMessage}' : ''}',
                        style: TextStyle(fontSize: 13, color: signal),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
            ],
            Text(
              '注册码',
              style: TextStyle(
                color: foam,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            TextField(
              controller: _codeCtrl,
              enabled: !_busy,
              style: TextStyle(color: foam),
              decoration: InputDecoration(
                hintText: '粘贴购买后获得的注册码',
                hintStyle: TextStyle(color: foam.withValues(alpha: 0.3)),
                border: const OutlineInputBorder(borderRadius: BorderRadius.zero),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.zero,
                  borderSide: BorderSide(color: foam.withValues(alpha: 0.2)),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.zero,
                  borderSide: BorderSide(color: signal),
                ),
              ),
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _activate(),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                style: TextStyle(fontSize: 12, color: Colors.red.shade300),
              ),
            ],
            const SizedBox(height: 12),
            FilledButton(
              onPressed: _busy ? null : _activate,
              style: FilledButton.styleFrom(
                minimumSize: const Size(0, 46),
                shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
              ),
              child: Text(_busy ? '正在激活…' : (_session.active ? '重新激活' : '立即激活')),
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                Text(
                  '可选套餐',
                  style: TextStyle(
                    color: foam,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                if (!_loadingPlans)
                  TextButton(
                    onPressed: _busy ? null : _loadPackages,
                    child: Text(
                      '刷新',
                      style: TextStyle(fontSize: 12, color: foam.withValues(alpha: 0.55)),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              canPay
                  ? '选一个套餐购买，付款后把注册码填到上面'
                  : '已有注册码直接在上面激活',
              style: TextStyle(fontSize: 12, color: foam.withValues(alpha: 0.4)),
            ),
            const SizedBox(height: 8),
            if (_loadingPlans)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Center(
                  child: SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: signal,
                    ),
                  ),
                ),
              )
            else if (packages.isEmpty)
              Text(
                _hint ?? '暂无在售套餐，如已有注册码可直接上方激活',
                style: TextStyle(fontSize: 12, color: foam.withValues(alpha: 0.5)),
              )
            else
              for (final p in packages)
                _PackageTile(
                  foam: foam,
                  signal: signal,
                  package: p,
                  onBuy: (!canPay || _busy)
                      ? null
                      : () => _openBuy(renew: _session.active),
                ),
            if (_ctx != null && !canPay && packages.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                '在线购买暂未开放，请向卖家索取注册码',
                style: TextStyle(fontSize: 12, color: foam.withValues(alpha: 0.55)),
              ),
            ],
            if (canPay) ...[
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: _busy ? null : () => _openBuy(renew: _session.active),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(0, 42),
                  shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
                ),
                child: Text(_session.active ? '去续费' : '去购买注册码'),
              ),
            ],
            if (_session.hasCode) ...[
              const SizedBox(height: 8),
              TextButton(
                onPressed: _busy ? null : _unbind,
                child: Text(
                  '解除本机绑定',
                  style: TextStyle(color: foam.withValues(alpha: 0.55)),
                ),
              ),
            ],
            const SizedBox(height: 8),
            InkWell(
              onTap: _copyDeviceId,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  children: [
                    Icon(Icons.smartphone, size: 14, color: foam.withValues(alpha: 0.35)),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        '本机编号（客服用）· 点按复制',
                        style: TextStyle(
                          fontSize: 11,
                          color: foam.withValues(alpha: 0.35),
                        ),
                      ),
                    ),
                    Icon(Icons.copy, size: 14, color: foam.withValues(alpha: 0.35)),
                  ],
                ),
              ),
            ),
            Text(
              projectName,
              style: TextStyle(fontSize: 10, color: foam.withValues(alpha: 0.25)),
            ),
          ],
        ),
      ),
    );
  }

  static String _friendlyError(Object e) {
    final raw = e.toString();
    if (raw.contains('未配置') || raw.contains('Integration') || raw.contains('Token')) {
      return '暂时无法联网校验，请稍后重试或联系客服';
    }
    if (raw.contains('Socket') ||
        raw.contains('Failed host') ||
        raw.contains('Connection') ||
        raw.contains('超时')) {
      return '网络异常，请检查网络后重试';
    }
    if (raw.startsWith('LicenseApiException:')) {
      return raw.replaceFirst('LicenseApiException:', '').trim();
    }
    if (raw.startsWith('Exception:')) {
      return raw.replaceFirst('Exception:', '').trim();
    }
    return raw;
  }
}

class _PackageTile extends StatelessWidget {
  const _PackageTile({
    required this.foam,
    required this.signal,
    required this.package,
    required this.onBuy,
  });

  final Color foam;
  final Color signal;
  final LicensePackage package;
  final VoidCallback? onBuy;

  @override
  Widget build(BuildContext context) {
    final duration = package.durationLabel;
    final devices = package.maxDevices;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: const Color(0xFF1A2220),
        child: InkWell(
          onTap: onBuy,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        package.packageName,
                        style: TextStyle(
                          color: foam,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        devices != null && devices > 0
                            ? '$duration · 可绑 $devices 台设备'
                            : duration,
                        style: TextStyle(
                          fontSize: 12,
                          color: foam.withValues(alpha: 0.45),
                        ),
                      ),
                    ],
                  ),
                ),
                Text(
                  _yuan(package.priceFen),
                  style: TextStyle(
                    color: signal,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (onBuy != null) ...[
                  const SizedBox(width: 8),
                  Icon(Icons.chevron_right, color: foam.withValues(alpha: 0.35)),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  static String _yuan(int fen) => '¥${(fen / 100).toStringAsFixed(fen % 100 == 0 ? 0 : 2)}';
}
