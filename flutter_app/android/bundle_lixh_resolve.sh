#!/usr/bin/env bash
# Cross-compile stream-stack resolve cdylib for Android arm64 and stage as jniLibs.
set -euo pipefail

API_LEVEL="${LIXH_ANDROID_API:-26}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/../.." && pwd)"
STACK="$REPO/src-tauri/lixh-stream-stack"
OUT_LIB="$STACK/target/aarch64-linux-android/release/liblixh_stream_resolver.so"
JNI_DIR="$SCRIPT_DIR/app/src/main/jniLibs/arm64-v8a"
JNI_SO="$JNI_DIR/liblixh_resolve.so"
JNI_FFI="$JNI_DIR/liblixh_stream_resolver.so"

NDK_ROOT="${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-}}"
if [[ -z "$NDK_ROOT" || ! -d "$NDK_ROOT" ]]; then
  SDK="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-}}"
  if [[ -n "$SDK" && -d "$SDK/ndk" ]]; then
    NDK_ROOT="$(ls -1d "$SDK/ndk"/* | sort -V | tail -n1)"
  fi
fi
if [[ -z "$NDK_ROOT" || ! -d "$NDK_ROOT" ]]; then
  echo "ANDROID_NDK_HOME / NDK not found" >&2
  exit 1
fi

PREBUILT="$(ls -1d "$NDK_ROOT"/toolchains/llvm/prebuilt/* | head -n1)"
CLANG="$PREBUILT/bin/aarch64-linux-android${API_LEVEL}-clang"
AR="$PREBUILT/bin/llvm-ar"
if [[ ! -x "$CLANG" ]]; then
  echo "NDK clang missing: $CLANG" >&2
  exit 1
fi

export ANDROID_NDK_HOME="$NDK_ROOT"
export ANDROID_NDK_ROOT="$NDK_ROOT"
export CC_aarch64_linux_android="$CLANG"
export AR_aarch64_linux_android="$AR"
export CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER="$CLANG"

echo "NDK=$NDK_ROOT"
echo "Building lixh-stream-resolver cdylib (aarch64-linux-android)…"
(
  cd "$STACK"
  rustup target add aarch64-linux-android >/dev/null 2>&1 || true
  cargo build -p lixh-stream-resolver --lib --release --target aarch64-linux-android
)

test -f "$OUT_LIB"
mkdir -p "$JNI_DIR"
cp -f "$OUT_LIB" "$JNI_FFI"
rm -f "$JNI_SO"
chmod 755 "$JNI_FFI"
echo "Staged $JNI_FFI ($(du -h "$JNI_FFI" | awk '{print $1}'))"
