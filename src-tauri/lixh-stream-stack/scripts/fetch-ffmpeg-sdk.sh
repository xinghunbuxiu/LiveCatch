#!/usr/bin/env bash
set -euo pipefail

REPO="${LIXH_FFMPEG_REPO:-xinghunbuxiu/LiveCatchFfmpeg}"
VERSION="${LIXH_FFMPEG_VERSION:-9.0.2}"
PLATFORM="${1:?platform required}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
OUT="${2:-$ROOT/src-tauri/lixh-stream-stack/sdk/$PLATFORM}"
TAG="${LIXH_FFMPEG_TAG:-ffmpeg-${VERSION}-lc1}"
ASSET="LiveCatch-ffmpeg-sdk-${VERSION}-${PLATFORM}.zip"

mkdir -p "$OUT"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Release assets are public; download the immutable asset directly instead of
# querying the GitHub Releases API, which can be rate-limited on hosted runners.
curl -fL --retry 5 --retry-delay 2 -o "$TMP/$ASSET"   "https://github.com/$REPO/releases/download/$TAG/$ASSET"

rm -rf "$OUT"
mkdir -p "$OUT"
unzip -q "$TMP/$ASSET" -d "$OUT"
echo "OK: FFmpeg SDK $PLATFORM -> $OUT"
