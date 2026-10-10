#!/usr/bin/env bash
# Copy/symlink LiveCatchFfmpeg ios-arm64 headers+libs into this pod so CocoaPods
# can vendor them with in-tree relative paths.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
SDK_SRC="${1:-$ROOT/src-tauri/lixh-stream-stack/sdk/ios-arm64}"
DST="$(cd "$(dirname "$0")" && pwd)/Frameworks"

if [[ ! -f "$SDK_SRC/include/libavcodec/avcodec.h" ]]; then
  echo "Missing FFmpeg SDK at $SDK_SRC" >&2
  echo "Run: bash src-tauri/lixh-stream-stack/scripts/fetch-ffmpeg-sdk.sh ios-arm64" >&2
  exit 1
fi

rm -rf "$DST"
mkdir -p "$DST/lib" "$DST/include"
# Prefer hard links / copy (Windows-friendly when run under Git Bash).
cp -a "$SDK_SRC/include/." "$DST/include/"
cp -a "$SDK_SRC/lib/." "$DST/lib/"
# Drop pkgconfig noise if present
rm -rf "$DST/lib/pkgconfig" || true
echo "OK: synced ios FFmpeg -> $DST"
ls -la "$DST/lib"/*.a
