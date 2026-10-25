#!/usr/bin/env bash
set -euo pipefail

REPO="${LIXH_FFMPEG_REPO:-xinghunbuxiu/LiveCatchFfmpeg}"
VERSION="${LIXH_FFMPEG_VERSION:-9.0.2}"
PLATFORM="${1:?platform required}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
OUT="${2:-$ROOT/src-tauri/lixh-stream-stack/runtime/$PLATFORM}"
ASSET="LiveCatch-ffmpeg-${VERSION}-${PLATFORM}.zip"

# Same tag ladder as fetch-ffmpeg-sdk.sh: newest first, older tags as fallback.
if [[ -n "${LIXH_FFMPEG_TAG:-}" ]]; then
  TAGS=("$LIXH_FFMPEG_TAG")
else
  TAGS=("ffmpeg-${VERSION}-lc2" "ffmpeg-${VERSION}-lc1")
fi

mkdir -p "$OUT"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

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
  exit 1
fi
echo "Using FFmpeg runtime $PLATFORM from $fetched"

rm -rf "$OUT"
mkdir -p "$OUT"
unzip -q "$TMP/$ASSET" -d "$OUT"

cat > "$OUT/runtime-manifest.json" <<EOF
{
  "repository": "$REPO",
  "version": "$VERSION",
  "platform": "$PLATFORM",
  "release_tag": "$fetched",
  "asset": "$ASSET",
  "consumed_from_release": true
}
EOF
echo "OK: FFmpeg runtime $PLATFORM -> $OUT"
