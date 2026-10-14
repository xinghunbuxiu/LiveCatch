import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'license_api.dart';
import 'license_session.dart';
import 'license_sheet.dart';
import 'rewardplay_config.dart';

enum LicenseGateReason {
  /// No code bound on this device.
  missing,

  /// Bound code expired / unbound / rejected by server.
  expired,

  /// Token missing or Open API not ready / network.
  unavailable,
}

class LicenseGateResult {
  const LicenseGateResult.ok(this.session)
      : allowed = true,
        reason = null,
        message = null;

  const LicenseGateResult.blocked({
    required this.session,
    required this.reason,
    required this.message,
  }) : allowed = false;

  final bool allowed;
  final LicenseSession session;
  final LicenseGateReason? reason;
  final String? message;

  bool get isExpired => reason == LicenseGateReason.expired;
  bool get isMissing => reason == LicenseGateReason.missing;

  String get webUrl =>
      isExpired ? kRewardPlayRenewalUrl : kRewardPlayCheckoutUrl;
}

bool _looksExpired(String msg) {
  final m = msg.toLowerCase();
  const keys = [
    '过期',
    '到期',
    '失效',
    'expired',
    'expire',
    '已解绑',
    '未绑定',
    '无效',
    '不存在',
    '禁用',
    '吊销',
    '撤销',
  ];
  return keys.any(m.contains);
}

/// Hard check before room resolve: must have a live binding via heartbeat.
Future<LicenseGateResult> ensureLicenseForPlayback({
  required LicenseApi api,
  required LicenseSession session,
}) async {
  if (!api.hasToken) {
    return LicenseGateResult.blocked(
      session: session,
      reason: LicenseGateReason.unavailable,
      message: '未配置权益凭证，无法校验授权',
    );
  }

  if (!session.hasCode) {
    return LicenseGateResult.blocked(
      session: session.copyWith(active: false, lastMessage: '未激活'),
      reason: LicenseGateReason.missing,
      message: '请先开通或激活权益后再解析直播间',
    );
  }

  try {
    final next = await session.heartbeat(api);
    return LicenseGateResult.ok(next);
  } on LicenseApiException catch (e) {
    final msg = e.message;
    final expired = _looksExpired(msg);
    final blocked = session.copyWith(active: false, lastMessage: msg);
    await blocked.save();
    return LicenseGateResult.blocked(
      session: blocked,
      reason: expired ? LicenseGateReason.expired : LicenseGateReason.unavailable,
      message: msg,
    );
  } catch (e) {
    final blocked = session.copyWith(
      active: false,
      lastMessage: e.toString(),
    );
    await blocked.save();
    return LicenseGateResult.blocked(
      session: blocked,
      reason: LicenseGateReason.unavailable,
      message: e.toString(),
    );
  }
}

Future<void> openLicenseWeb(String url) async {
  final uri = Uri.parse(url);
  final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
  if (!ok) {
    throw LicenseApiException('无法打开权益页面');
  }
}

/// Returns true if the user may continue (license became valid, or they
/// cancelled and caller should abort). [false] = abort start.
Future<bool> showLicenseBlockedDialog(
  BuildContext context, {
  required LicenseGateResult gate,
  required LicenseSession session,
  required ValueChanged<LicenseSession> onSession,
}) async {
  final foam = Theme.of(context).colorScheme.onSurface;
  final title = gate.isMissing
      ? '需要开通权益'
      : (gate.isExpired ? '权益已到期' : '权益校验失败');
  final body = gate.message ?? '请开通或续费后再解析直播间';
  final webLabel = gate.isExpired ? '去续费' : '去开通';

  final action = await showDialog<String>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      backgroundColor: const Color(0xFF1A2220),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
      title: Text(title, style: TextStyle(color: foam)),
      content: Text(body, style: TextStyle(color: foam.withValues(alpha: 0.8))),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, 'cancel'),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(ctx, 'code'),
          child: const Text('输入授权码'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, 'web'),
          style: FilledButton.styleFrom(
            shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
          ),
          child: Text(webLabel),
        ),
      ],
    ),
  );

  if (!context.mounted) return false;

  if (action == 'web') {
    try {
      await openLicenseWeb(gate.webUrl);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$e')),
        );
      }
    }
    return false;
  }

  if (action == 'code') {
    final next = await showLicenseSheet(context, session: session);
    if (next != null) {
      onSession(next);
      if (next.active && next.hasCode) return true;
    }
    return false;
  }

  return false;
}
