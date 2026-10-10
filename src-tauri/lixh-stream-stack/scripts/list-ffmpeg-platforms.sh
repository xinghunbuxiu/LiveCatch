#!/usr/bin/env bash
# Canonical platform ids for LiveCatch FFmpeg SDK/runtime assets.
# Desktop (published on ffmpeg-9.0.2-lc1):
#   windows-x64  macos-arm64  macos-x64
# Mobile (built by LiveCatchFfmpeg Actions; publish to same release tag):
#   android-arm64  ios-arm64
set -euo pipefail
printf '%s\n' \
  windows-x64 \
  macos-arm64 \
  macos-x64 \
  android-arm64 \
  ios-arm64
