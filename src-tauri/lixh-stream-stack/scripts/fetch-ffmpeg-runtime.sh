#!/usr/bin/env bash
set -euo pipefail
REPO="${LIXH_FFMPEG_REPO:-xinghunbuxiu/LiveCatchFfmpeg}"
VERSION="${LIXH_FFMPEG_VERSION:-9.0.2}"
PLATFORM="${1:?platform required}"
OUT="${2:?output directory required}"
TAG="${LIXH_FFMPEG_TAG:-ffmpeg-${VERSION}}"
ASSET="LiveCatch-ffmpeg-${VERSION}-${PLATFORM}.zip"
mkdir -p "$OUT"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
if command -v gh >/dev/null 2>&1; then
  gh release download "$TAG" --repo "$REPO" --pattern "$ASSET" --dir "$TMP" --clobber
else
  curl -fL --retry 3 -o "$TMP/$ASSET" "https://github.com/$REPO/releases/download/$TAG/$ASSET"
fi
rm -rf "$OUT"
mkdir -p "$OUT"
unzip -q "$TMP/$ASSET" -d "$OUT"
cat > "$OUT/runtime-manifest.json" <<EOF
{
  "repository": "$REPO",
  "version": "$VERSION",
  "platform": "$PLATFORM",
  "release_tag": "$TAG",
  "asset": "$ASSET",
  "consumed_from_release": true
}
EOF
