#!/usr/bin/env bash
# Download + unpack FFmpeg runtime/SDK for one platform and smoke-check layout.
# Usage: verify-ffmpeg-consume.sh <platform> [--optional]
#   --optional: exit 0 with warning if the release asset is missing (404).
set -euo pipefail

PLATFORM="${1:?platform required}"
OPTIONAL=0
if [[ "${2:-}" == "--optional" ]]; then
  OPTIONAL=1
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
STACK="$ROOT/src-tauri/lixh-stream-stack"
REPO="${LIXH_FFMPEG_REPO:-xinghunbuxiu/LiveCatchFfmpeg}"
VERSION="${LIXH_FFMPEG_VERSION:-9.0.2}"
TAG="${LIXH_FFMPEG_TAG:-ffmpeg-${VERSION}-lc1}"
RUNTIME_ASSET="LiveCatch-ffmpeg-${VERSION}-${PLATFORM}.zip"
SDK_ASSET="LiveCatch-ffmpeg-sdk-${VERSION}-${PLATFORM}.zip"
RUNTIME_URL="https://github.com/$REPO/releases/download/$TAG/$RUNTIME_ASSET"
SDK_URL="https://github.com/$REPO/releases/download/$TAG/$SDK_ASSET"

probe() {
  local url="$1"
  local code
  code="$(curl -sL -o /dev/null -w '%{http_code}' --retry 2 "$url" || true)"
  echo "$code"
}

rt_code="$(probe "$RUNTIME_URL")"
sdk_code="$(probe "$SDK_URL")"
if [[ "$rt_code" != "200" || "$sdk_code" != "200" ]]; then
  msg="FFmpeg assets missing for $PLATFORM (runtime=$rt_code sdk=$sdk_code) tag=$TAG"
  if [[ "$OPTIONAL" -eq 1 ]]; then
    echo "WARN: $msg — skipping (optional platform)."
    exit 0
  fi
  echo "ERROR: $msg" >&2
  exit 1
fi

RUNTIME_OUT="$STACK/runtime/$PLATFORM"
SDK_OUT="$STACK/sdk/$PLATFORM"
bash "$STACK/scripts/fetch-ffmpeg-runtime.sh" "$PLATFORM" "$RUNTIME_OUT"
bash "$STACK/scripts/fetch-ffmpeg-sdk.sh" "$PLATFORM" "$SDK_OUT"

# Layout smoke checks (shared across desktop/mobile packages).
test -d "$SDK_OUT/include" || { echo "missing $SDK_OUT/include" >&2; exit 1; }
test -d "$SDK_OUT/lib" || { echo "missing $SDK_OUT/lib" >&2; exit 1; }
test -d "$RUNTIME_OUT" || { echo "missing $RUNTIME_OUT" >&2; exit 1; }

case "$PLATFORM" in
  windows-x64)
    test -f "$SDK_OUT/include/libavcodec/avcodec.h"
    ls "$RUNTIME_OUT"/*.dll >/dev/null 2>&1 || ls "$RUNTIME_OUT"/bin/*.dll >/dev/null 2>&1
    ;;
  macos-*)
    test -f "$SDK_OUT/include/libavcodec/avcodec.h"
    ls "$SDK_OUT/lib"/libavcodec* >/dev/null 2>&1 || {
      echo "missing libavcodec under $SDK_OUT/lib" >&2
      exit 1
    }
    ;;
  ios-arm64)
    test -f "$SDK_OUT/include/libavcodec/avcodec.h"
    test -f "$SDK_OUT/lib/libavcodec.a" || {
      echo "missing $SDK_OUT/lib/libavcodec.a (iOS static SDK)" >&2
      exit 1
    }
    test -f "$RUNTIME_OUT/lib/libavcodec.a" || test -f "$RUNTIME_OUT/libavcodec.a" || {
      echo "missing iOS runtime libavcodec.a under $RUNTIME_OUT" >&2
      exit 1
    }
    ;;
  android-arm64)
    test -f "$SDK_OUT/include/libavcodec/avcodec.h"
    test -f "$SDK_OUT/lib/libavcodec.so" || test -f "$SDK_OUT/lib/arm64-v8a/libavcodec.so" || {
      echo "missing android SDK libavcodec.so under $SDK_OUT/lib" >&2
      exit 1
    }
    # LiveCatchFfmpeg runtime zip: arm64-v8a/*.so
    if ! ls "$RUNTIME_OUT"/arm64-v8a/*.so >/dev/null 2>&1 &&
       ! ls "$RUNTIME_OUT"/*.so >/dev/null 2>&1 &&
       ! ls "$RUNTIME_OUT"/lib/*.so >/dev/null 2>&1 &&
       ! ls "$RUNTIME_OUT"/lib/arm64-v8a/*.so >/dev/null 2>&1; then
      echo "missing android runtime .so under $RUNTIME_OUT (expected arm64-v8a/)" >&2
      exit 1
    fi
    ;;
esac

echo "OK: verified FFmpeg consume for $PLATFORM"
