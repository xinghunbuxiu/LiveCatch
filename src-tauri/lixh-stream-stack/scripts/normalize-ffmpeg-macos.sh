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

# install_name_tool can exit non-zero when a change is a no-op or when the
# Mach-O already has the desired id (common on re-normalize). Treat those as OK.
soft_install_name_tool() {
  local out
  if out="$(install_name_tool "$@" 2>&1)"; then
    return 0
  fi
  if [[ "$out" == *"is not a Mach-O"* ]] || [[ "$out" == *"can't open file"* ]]; then
    echo "$out" >&2
    return 1
  fi
  # No-op / already-normalized / codesign warning — keep going.
  echo "install_name_tool warning (ignored): $out" >&2
  return 0
}

# The published SDK may contain dylibs whose install names still point at the
# build machine used by LiveCatchFfmpeg. Normalize those names before linking
# so LiveCatch remains relocatable and CI runners never depend on that path.
LIBS=()
while IFS= read -r dylib; do
  LIBS+=( "$dylib" )
done < <(find "$LIB" -type f -name '*.dylib' -print)

if [[ ${#LIBS[@]} -eq 0 ]]; then
  echo "No FFmpeg dylibs under $LIB" >&2
  exit 1
fi

for dylib in "${LIBS[@]}"; do
  soft_install_name_tool -id "@rpath/$(basename "$dylib")" "$dylib"
done

for dylib in "${LIBS[@]}"; do
  while IFS= read -r dep; do
    [[ "$dep" == /* ]] || continue
    base="$(basename "$dep")"
    case "$base" in
      libav*.dylib|libsw*.dylib|libpostproc*.dylib)
        if [[ -f "$LIB/$base" ]]; then
          soft_install_name_tool -change "$dep" "@rpath/$base" "$dylib"
        fi
        ;;
    esac
  done < <(otool -L "$dylib" | tail -n +2 | sed 's/^[[:space:]]*//' | cut -d' ' -f1)
done

echo "Normalized ${#LIBS[@]} FFmpeg macOS dylibs under $LIB"
