#!/usr/bin/env bash
# Sync LiveCatchFfmpeg macos-* + lixh_player.h into this pod for CocoaPods.
set -euo pipefail

POD_MACOS="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$POD_MACOS/../../.." && pwd)"
PLAT="${1:-macos-arm64}"
SDK_SRC="${2:-$ROOT/src-tauri/lixh-stream-stack/sdk/$PLAT}"
CORE_HDR="$ROOT/src-tauri/lixh-stream-stack/lixh-player-core/include/lixh_player.h"
DST_FW="$POD_MACOS/Frameworks"
DST_HDR="$POD_MACOS/lixh_player/Sources/lixh_player_corec/include/lixh_player.h"

if [[ ! -f "$SDK_SRC/include/libavcodec/avcodec.h" ]]; then
  echo "Missing FFmpeg SDK at $SDK_SRC" >&2
  echo "Run: bash src-tauri/lixh-stream-stack/scripts/fetch-ffmpeg-sdk.sh $PLAT" >&2
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

cp -f "$CORE_HDR" "$DST_HDR"

# Relocate install names for bundling under @rpath.
if [[ -x "$ROOT/src-tauri/lixh-stream-stack/scripts/normalize-ffmpeg-macos.sh" ]]; then
  bash "$ROOT/src-tauri/lixh-stream-stack/scripts/normalize-ffmpeg-macos.sh" "$DST_FW"
fi

echo "OK: synced $PLAT FFmpeg -> $DST_FW"
echo "OK: synced lixh_player.h -> $DST_HDR"
ls -la "$DST_FW/lib"/libavutil*.dylib
