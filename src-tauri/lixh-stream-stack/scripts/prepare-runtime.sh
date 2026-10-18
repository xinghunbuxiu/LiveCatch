#!/usr/bin/env bash
set -euo pipefail

PLATFORM="${1:?platform required}"
OUT="${LIXH_FFMPEG_RUNTIME_DIR:-src-tauri/lixh-stream-stack/runtime/$PLATFORM}"

bash "$(dirname "$0")/fetch-ffmpeg-runtime.sh" "$PLATFORM" "$OUT"
