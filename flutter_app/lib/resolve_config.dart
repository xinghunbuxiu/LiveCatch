/// Remote room-resolve endpoint (native platforms on server; no client extractors).
///
/// Override at build time:
///   flutter run --dart-define=LIXH_RESOLVE_BASE_URL=http://127.0.0.1:9101 \
///               --dart-define=LIXH_RESOLVE_API_KEY=...
const String kResolveBaseUrl = String.fromEnvironment(
  'LIXH_RESOLVE_BASE_URL',
  defaultValue: 'http://101.35.40.114/livecatch',
);

/// Legacy static key. Deliberately empty by default.
///
/// A key compiled into the APK is not a security boundary: it can be extracted
/// with `strings libapp.so` and replayed by anyone, so the resolver no longer
/// relies on it — access is decided by the RewardPlay entitlement the app
/// already carries (licence code + device id, verified server-side).
///
/// The header is still sent when a build supplies this value, which keeps
/// older deployments working during rollout. Pass it only for that purpose.
const String kResolveApiKey = String.fromEnvironment(
  'LIXH_RESOLVE_API_KEY',
  defaultValue: '',
);
