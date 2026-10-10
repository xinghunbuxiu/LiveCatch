#!/usr/bin/env bash
# Sync LiveCatchFfmpeg ios-arm64 + lixh_player.h into this pod (in-tree paths
# required by CocoaPods vendored_libraries / modular headers).
set -euo pipefail

POD_IOS="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$POD_IOS/../../.." && pwd)"
SDK_SRC="${1:-$ROOT/src-tauri/lixh-stream-stack/sdk/ios-arm64}"
CORE_HDR="$ROOT/src-tauri/lixh-stream-stack/lixh-player-core/include/lixh_player.h"
DST_FW="$POD_IOS/Frameworks"
DST_HDR="$POD_IOS/lixh_player/Sources/lixh_player_corec/include/lixh_player.h"

if [[ ! -f "$SDK_SRC/include/libavcodec/avcodec.h" ]]; then
  echo "Missing FFmpeg SDK at $SDK_SRC" >&2
  echo "Run: bash src-tauri/lixh-stream-stack/scripts/fetch-ffmpeg-sdk.sh ios-arm64" >&2
  exit 1
fi
if [[ ! -f "$CORE_HDR" ]]; then
  echo "Missing $CORE_HDR" >&2
  exit 1
fi

rm -rf "$DST_FW"
mkdir -p "$DST_FW/lib" "$DST_FW/include"
cp -a "$SDK_SRC/include/." "$DST_FW/include/"
cp -a "$SDK_SRC/lib/." "$DST_FW/lib/"
rm -rf "$DST_FW/lib/pkgconfig" || true

# Keep a copy next to the ObjC/C sources so the Clang module can see it.
cp -f "$CORE_HDR" "$DST_HDR"

echo "OK: synced ios FFmpeg -> $DST_FW"
echo "OK: synced lixh_player.h -> $DST_HDR"
ls -la "$DST_FW/lib"/*.a
