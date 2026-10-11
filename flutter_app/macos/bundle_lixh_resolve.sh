#!/usr/bin/env bash
# Copy stream-stack lixh_resolve into the macOS .app next to the main binary.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
STACK="$ROOT/src-tauri/lixh-stream-stack"
RESOLVE="$STACK/target/release/lixh_resolve"
APP="${1:-}"

if [[ -z "$APP" ]]; then
  APP="$(find "$ROOT/flutter_app/build/macos" -type d -name '*.app' -path '*/Build/Products/Release/*' 2>/dev/null | head -n 1 || true)"
fi
if [[ -z "$APP" || ! -d "$APP" ]]; then
  echo "macOS .app not found (pass path as arg1)" >&2
  exit 1
fi

if [[ ! -x "$RESOLVE" ]]; then
  echo "Building lixh_resolve…"
  cargo build -p lixh-stream-resolver --bin lixh_resolve --release \
    --manifest-path "$STACK/Cargo.toml"
fi
test -x "$RESOLVE"

DEST="$APP/Contents/MacOS/lixh_resolve"
cp -f "$RESOLVE" "$DEST"
chmod +x "$DEST"
# Ad-hoc sign so Gatekeeper accepts the helper beside the app binary.
codesign --force --sign - "$DEST" 2>/dev/null || true
echo "OK: bundled $DEST"
ls -lah "$DEST"
