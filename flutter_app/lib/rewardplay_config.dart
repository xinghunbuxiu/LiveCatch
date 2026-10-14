/// RewardPlay Open License config for LiveCatch (`LIVE_CATCH`).
///
/// Build with:
/// ```bash
/// flutter run \
///   --dart-define=REWARDPLAY_BASE_URL=http://101.35.40.114 \
///   --dart-define=REWARDPLAY_INTEGRATION_TOKEN=rpt_... \
///   --dart-define=REWARDPLAY_PROJECT_CODE=LIVE_CATCH
/// ```
/// Local helper file (gitignored): `flutter_app/.env.rewardplay.local`
const String kRewardPlayBaseUrl = String.fromEnvironment(
  'REWARDPLAY_BASE_URL',
  defaultValue: 'http://101.35.40.114',
);

const String kRewardPlayProjectCode = String.fromEnvironment(
  'REWARDPLAY_PROJECT_CODE',
  defaultValue: 'LIVE_CATCH',
);

/// Project Integration Token (`rpt_…`). Prefer dart-define; never commit real tokens.
const String kRewardPlayIntegrationToken = String.fromEnvironment(
  'REWARDPLAY_INTEGRATION_TOKEN',
);

String get kRewardPlayCheckoutUrl {
  final base = kRewardPlayBaseUrl.replaceAll(RegExp(r'/+$'), '');
  return '$base/?entry=license-checkout&projectCode=$kRewardPlayProjectCode';
}

String get kRewardPlayRenewalUrl {
  final base = kRewardPlayBaseUrl.replaceAll(RegExp(r'/+$'), '');
  return '$base/?entry=license-renewal&projectCode=$kRewardPlayProjectCode';
}
