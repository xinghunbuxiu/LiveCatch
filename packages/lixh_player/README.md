# lixh_player

Flutter plugin for LiveCatch low-latency playback. Dart API is shared; native backends differ by platform.

## API

`open` / `play` / `stop` / `setVideoEnabled` / `getStats` / `createVideoTexture` / `disposeVideoTexture`

Audio-first: `setVideoEnabled(false)` skips present so demux stays on audio.

## Platform status

| Platform | Status |
|----------|--------|
| **Windows** | Full: DXGI shared texture + `lixh-player-core` + WASAPI + D3D11 VA/VP |
| **macOS** | Core + AudioQueue + FlutterTexture (software / VT frames). Fetch `sdk/macos-arm64` or `macos-x64` first |
| **iOS** | Core + AudioQueue + FlutterTexture (device arm64). Fetch `sdk/ios-arm64` first |
| **Android** | Core + AAudio + MediaCodec→SW transfer + SurfaceTexture (arm64-v8a + armeabi-v7a) |

## FFmpeg layout

SDK/runtime zips live under `src-tauri/lixh-stream-stack/`:

```bash
# Git Bash
bash src-tauri/lixh-stream-stack/scripts/fetch-ffmpeg-sdk.sh windows-x64
bash src-tauri/lixh-stream-stack/scripts/fetch-ffmpeg-sdk.sh macos-arm64
bash src-tauri/lixh-stream-stack/scripts/fetch-ffmpeg-sdk.sh android-arm64
bash src-tauri/lixh-stream-stack/scripts/fetch-ffmpeg-sdk.sh android-armv7
bash src-tauri/lixh-stream-stack/scripts/fetch-ffmpeg-sdk.sh ios-arm64
```

Mobile SDK/runtime zips are on the LiveCatchFfmpeg Release tag
`ffmpeg-9.0.2-lc1` (workflow **Publish Mobile FFmpeg to Release**). Prefer
`fetch-ffmpeg-sdk.sh` / `fetch-ffmpeg-runtime.sh`; use
`fetch-ffmpeg-from-actions.sh` only for an unpublished Actions run.

## Latency roadmap

1. ~~Split demux/decode from Present~~ (Windows: Capture on demux, VP/Flush on present thread)
2. ~~Audio ring buffer~~ (Windows WASAPI ring; macOS/iOS/Android already ring-based)
3. macOS/iOS: chase 200/700 + `video_sink` listen-mode (done in engines; keep tuning)
4. ~~ABR~~: Flutter `AbrSupervisor` switches `room_resolve` candidates (stall / upshift)
5. ~~Android SurfaceTexture + MediaCodec decode~~ (direct MediaCodec→Surface later)
