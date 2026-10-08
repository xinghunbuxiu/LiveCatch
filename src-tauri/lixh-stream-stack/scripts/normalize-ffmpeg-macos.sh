#!/usr/bin/env bash
set -euo pipefail

ROOT="${1:?FFmpeg SDK root required}"
LIB="$ROOT/lib"

if [[ ! -d "$LIB" ]]; then
  echo "FFmpeg library directory not found: $LIB" >&2
  exit 1
fi

command -v install_name_tool >/dev/null
command -v otool >/dev/null

# The published SDK may contain dylibs whose install names still point at the
# build machine used by LiveCatchFfmpeg. Normalize those names before linking
# so LiveCatch remains relocatable and CI runners never depend on that path.
mapfile -d '' LIBS < <(find "$LIB" -type f -name '*.dylib' -print0)

for dylib in "${LIBS[@]}"; do
  install_name_tool -id "@rpath/$(basename "$dylib")" "$dylib"
done

for dylib in "${LIBS[@]}"; do
  while IFS= read -r dep; do
    [[ "$dep" == /* ]] || continue
    base="$(basename "$dep")"
    case "$base" in
      libav*.dylib|libsw*.dylib|libpostproc*.dylib)
        if [[ -f "$LIB/$base" ]]; then
          install_name_tool -change "$dep" "@rpath/$base" "$dylib"
        fi
        ;;
    esac
  done < <(otool -L "$dylib" | tail -n +2 | sed 's/^[[:space:]]*//' | cut -d' ' -f1)
done

echo "Normalized ${#LIBS[@]} FFmpeg macOS dylibs under $LIB"
