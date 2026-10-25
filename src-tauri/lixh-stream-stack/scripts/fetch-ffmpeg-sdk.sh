#!/usr/bin/env bash
set -euo pipefail

REPO="${LIXH_FFMPEG_REPO:-xinghunbuxiu/LiveCatchFfmpeg}"
VERSION="${LIXH_FFMPEG_VERSION:-9.0.2}"
PLATFORM="${1:?platform required}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
OUT="${2:-$ROOT/src-tauri/lixh-stream-stack/sdk/$PLATFORM}"
ASSET="LiveCatch-ffmpeg-sdk-${VERSION}-${PLATFORM}.zip"

# Tag selection. lc2 carries the MediaCodec-enabled Android builds; the other
# platforms were last published under lc1, so try the newest tag first and fall
# back through older ones. Pin a single tag with LIXH_FFMPEG_TAG.
if [[ -n "${LIXH_FFMPEG_TAG:-}" ]]; then
  TAGS=("$LIXH_FFMPEG_TAG")
else
  TAGS=("ffmpeg-${VERSION}-lc2" "ffmpeg-${VERSION}-lc1")
fi

mkdir -p "$OUT"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Release assets are public; download the immutable asset directly instead of
# querying the GitHub Releases API, which can be rate-limited on hosted runners.
fetched=""
for tag in "${TAGS[@]}"; do
  url="https://github.com/$REPO/releases/download/$tag/$ASSET"
  if curl -fL --retry 3 --retry-delay 2 -o "$TMP/$ASSET" "$url"; then
    fetched="$tag"
    break
  fi
  echo "  $ASSET not in $tag, trying next…" >&2
done
if [[ -z "$fetched" ]]; then
  echo "ERROR: $ASSET missing from every tag tried: ${TAGS[*]}" >&2
  echo "        Publish it from the LiveCatchFfmpeg workflow first." >&2
  exit 1
fi
echo "Using FFmpeg SDK $PLATFORM from $fetched"

rm -rf "$OUT"
mkdir -p "$OUT"
unzip -q "$TMP/$ASSET" -d "$OUT"
echo "OK: FFmpeg SDK $PLATFORM -> $OUT"
