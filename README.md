# LiveCatch

Low-latency live catcher. **Flutter** multiplatform app (`flutter_app/`).

## Layout

```
liveCatch/
  flutter_app/                 # Main app: windows / macos / ios / android
  packages/lixh_player/        # Plugin: windows + macos + ios native; android audio-first
  src-tauri/lixh-stream-stack/ # Shared FFmpeg + player-core + room resolver (not a Tauri app)
    sdk/ runtime/              # Per-platform FFmpeg (fetch scripts)
    lixh-player-core/          # Shared C player core
    scripts/fetch-ffmpeg-*.sh
  .github/workflows/           # Flutter, FFmpeg consume, stream-stack cargo verify
```

## FFmpeg

Built in [LiveCatchFfmpeg](https://github.com/xinghunbuxiu/LiveCatchFfmpeg). Consume:

```bash
# OUT defaults to sdk/<platform> or runtime/<platform>
bash src-tauri/lixh-stream-stack/scripts/fetch-ffmpeg-sdk.sh <platform>
bash src-tauri/lixh-stream-stack/scripts/fetch-ffmpeg-runtime.sh <platform>
# Windows (no bash): powershell -File src-tauri/lixh-stream-stack/scripts/fetch-ffmpeg.ps1 windows-x64
```

Platforms: `windows-x64`, `macos-arm64`, `macos-x64`, `android-arm64`, `ios-arm64`.  
CI: `.github/workflows/verify-ffmpeg-consume.yml` (all five required).

## Run

```bash
bash src-tauri/lixh-stream-stack/scripts/fetch-ffmpeg-sdk.sh windows-x64
bash src-tauri/lixh-stream-stack/scripts/fetch-ffmpeg-runtime.sh windows-x64

# Room resolve helper used by Flutter (Windows)
cargo build -p lixh-stream-resolver --bin lixh_resolve \
  --manifest-path src-tauri/lixh-stream-stack/Cargo.toml

cd flutter_app && flutter pub get && flutter run -d windows
# macOS / iOS / Android: fetch that platform's sdk+runtime, then flutter run -d <device>
```

## Roadmap (short)

1. Device smoke: iOS full / Android audio + SurfaceTexture  
2. ~~ABR~~ (`flutter_app/lib/abr_supervisor.dart` + CI unit tests)  
3. ~~Android MediaCodec decode~~ (transfer → SurfaceTexture; direct Surface later)
