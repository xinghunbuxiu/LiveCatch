# livecatch_app

Flutter shell for LiveCatch (primary app path). Uses [`lixh_player`](../packages/lixh_player).

## Platforms

| Target | App scaffold | Player |
|--------|--------------|--------|
| Windows | yes | native (playable) |
| macOS | yes | native (audio + FlutterTexture; needs FFmpeg sdk) |
| iOS | yes | native (audio + texture; needs FFmpeg sdk/ios-arm64) |
| Android | yes | native listen (AAudio; needs FFmpeg sdk/android-arm64 + android-armv7) |

```bash
# Desktop FFmpeg (once)
bash ../src-tauri/lixh-stream-stack/scripts/fetch-ffmpeg-sdk.sh windows-x64 \
  ../src-tauri/lixh-stream-stack/sdk/windows-x64

cd flutter_app
flutter pub get
flutter run -d windows

# Mobile (after LiveCatchFfmpeg publishes android/ios zips):
# bash ../src-tauri/lixh-stream-stack/scripts/fetch-ffmpeg-sdk.sh android-arm64 ...
# bash ../src-tauri/lixh-stream-stack/scripts/fetch-ffmpeg-sdk.sh android-armv7 ...
# bash ../src-tauri/lixh-stream-stack/scripts/fetch-ffmpeg-sdk.sh ios-arm64 ...
# flutter run -d <device>
```

Windows: Impeller is disabled for DXGI texture stability (`windows/runner` / launch args as configured).

## Layout

- `lib/main.dart` — audio-first UI + HUD stats
- `lib/room_resolve.dart` — room → stream URL / bitrate candidates
