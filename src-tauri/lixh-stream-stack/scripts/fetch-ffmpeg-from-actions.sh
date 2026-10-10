#!/usr/bin/env bash
# Download FFmpeg packages from a LiveCatchFfmpeg Actions run (artifact), then
# unpack into sdk/ and runtime/ the same way Release fetch scripts do.
#
# Prefer Release assets once published. Use this when CI only has artifacts.
#
# Usage:
#   fetch-ffmpeg-from-actions.sh <platform> <run_id> [repo-root]
# Example:
#   fetch-ffmpeg-from-actions.sh android-arm64 37881980163
#   fetch-ffmpeg-from-actions.sh ios-arm64 37881894114
#
# Requires: gh (authenticated), unzip
set -euo pipefail

PLATFORM="${1:?platform required (android-arm64|ios-arm64)}"
RUN_ID="${2:?Actions run id required}"
ROOT="$(cd "${3:-$(dirname "$0")/../../..}" && pwd)"
REPO="${LIXH_FFMPEG_REPO:-xinghunbuxiu/LiveCatchFfmpeg}"
VERSION="${LIXH_FFMPEG_VERSION:-9.0.2}"

case "$PLATFORM" in
  android-arm64|ios-arm64) ;;
  *)
    echo "This helper is for mobile platforms only (got: $PLATFORM)" >&2
    exit 2
    ;;
esac

command -v gh >/dev/null || {
  echo "gh CLI required (https://cli.github.com/). Authenticate with: gh auth login" >&2
  exit 1
}

SDK_OUT="$ROOT/src-tauri/lixh-stream-stack/sdk/$PLATFORM"
RT_OUT="$ROOT/src-tauri/lixh-stream-stack/runtime/$PLATFORM"
SDK_ZIP="LiveCatch-ffmpeg-sdk-${VERSION}-${PLATFORM}.zip"
RT_ZIP="LiveCatch-ffmpeg-${VERSION}-${PLATFORM}.zip"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "Downloading artifacts from $REPO run $RUN_ID ..."
gh run download "$RUN_ID" --repo "$REPO" --dir "$TMP/art"

SDK_PATH="$(find "$TMP/art" -type f -name "$SDK_ZIP" | head -n 1 || true)"
RT_PATH="$(find "$TMP/art" -type f -name "$RT_ZIP" | head -n 1 || true)"
if [[ -z "$SDK_PATH" || -z "$RT_PATH" ]]; then
  echo "Missing expected zips under artifact tree:" >&2
  find "$TMP/art" -type f -name '*.zip' -print >&2 || true
  echo "Wanted: $SDK_ZIP and $RT_ZIP" >&2
  exit 1
fi

rm -rf "$SDK_OUT" "$RT_OUT"
mkdir -p "$SDK_OUT" "$RT_OUT"
unzip -q "$SDK_PATH" -d "$SDK_OUT"
unzip -q "$RT_PATH" -d "$RT_OUT"

test -d "$SDK_OUT/include"
test -d "$SDK_OUT/lib"

cat > "$RT_OUT/runtime-manifest.json" <<EOF
{
  "repository": "$REPO",
  "version": "$VERSION",
  "platform": "$PLATFORM",
  "actions_run_id": "$RUN_ID",
  "sdk_asset": "$SDK_ZIP",
  "runtime_asset": "$RT_ZIP",
  "consumed_from_actions": true
}
EOF

echo "OK: sdk -> $SDK_OUT"
echo "OK: runtime -> $RT_OUT"
