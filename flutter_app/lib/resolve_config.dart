/// Remote room-resolve endpoint (keeps platforms-parser off device).
///
/// Override at build time:
///   flutter run --dart-define=LIXH_RESOLVE_BASE_URL=http://127.0.0.1:9101 \
///               --dart-define=LIXH_RESOLVE_API_KEY=...
const String kResolveBaseUrl = String.fromEnvironment(
  'LIXH_RESOLVE_BASE_URL',
  defaultValue: 'http://101.35.40.114/livecatch',
);

const String kResolveApiKey = String.fromEnvironment(
  'LIXH_RESOLVE_API_KEY',
  defaultValue: 'lc_resolve_2026_xhb_7f3a9c2e1b84',
);
