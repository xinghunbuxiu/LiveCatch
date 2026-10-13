# Graph Report - liveCatch  (2026-10-13)

## Corpus Check
- 151 files · ~70,175 words
- Verdict: corpus is large enough that graph structure adds value.
- Unclassified: 113 file(s) not represented in the graph (top: (none) 21, .xcconfig 16, .xml 15)

## Summary
- 1818 nodes · 2729 edges · 127 communities (71 shown, 56 thin omitted)
- Extraction: 95% EXTRACTED · 5% INFERRED · 0% AMBIGUOUS · INFERRED: 123 edges (avg confidence: 0.85)
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `fefc2520`
- Run `git rev-parse HEAD` and compare to check if the graph is stale.
- Run `graphify update .` after code changes (no API cost).

## Community Hubs (Navigation)
- flutter_app/lib/main.dart
- lixh_player.dart
- room_resolve.dart
- NativeSurface
- AudioOutput
- FlutterWindow
- example/windows/runner/win32_window.cpp
- SharedTextureBridge
- PlaybackForegroundService.kt
- RegisterPlugins
- LixhPlayerPlugin
- FfmpegRuntime
- abr_supervisor.dart
- FlutterWindow
- LixhPlayerPlugin
- lixh_player_platform_interface.dart
- douyin_expand.dart
- surface.rs
- Session
- lixh-stream-resolver/src/lib.rs
- LixhAudioOutput
- lixh_player_jni.cpp
- lixh_player.c
- PlayerSession
- playback_keepalive.dart
- douyin_expand.rs
- StreamCandidate
- player_session.cpp
- AudioOut
- lixh_player_test.dart
- LixhPlayerEngine
- LixhPlayerEngine
- app_settings.dart
- settings_sheet.dart
- example/lib/main.dart
- package:flutter_test/flutter_test.dart
- LixhPlayerPlugin
- PlaybackEngine<B>
- live_input.dart
- shared_texture.cpp
- lixh-playback-engine/src/lib.rs
- Cocoa
- native_surface.rs
- LixhPixelTexture
- surface_windows.rs
- Flutter
- .Open
- LixhPixelTexture
- LixhPlayerEngine
- LixhPlayerEngine
- Stats
- .Open
- .MessageHandler
- AppDelegate
- RetiredPair
- _PlayerPageState
- LixhAudioOutput
- LixhAudioOutput
- AppDelegate
- example/macos/RunnerTests/RunnerTests.swift
- AppDelegate
- ios/lixh_player/Package.swift
- android/bundle_lixh_resolve.sh
- StatelessWidget
- PlaybackBackend
- .MessageHandler
- lixh_resolve.rs
- lixh_player_method_channel.dart
- lixh-stream-supervisor
- lixh_player_example/MainActivity.kt
- lixh_player_get_stats
- normalize-ffmpeg-macos.sh
- verify-ffmpeg-consume.sh
- macos/bundle_lixh_resolve.sh
- sync_ffmpeg_ios.sh
- sync_ffmpeg_macos.sh
- fetch-ffmpeg-from-actions.sh
- fetch-ffmpeg-runtime.sh
- fetch-ffmpeg-sdk.sh
- list-ffmpeg-platforms.sh
- prepare-runtime.sh
- flutter_app/windows/runner/flutter_window.cpp
- Win32Window
- .create
- WindowClassRegistrar
- package:flutter/services.dart
- flutter_app/windows/runner/win32_window.cpp
- Java_com_livecatch_lixh_1player_LixhPlayerPlugin_nativeLastError
- LiveCatch
- Agent workflow: Graphify
- livecatch_app
- douyin_expand_test.dart
- .Create
- Point
- Size
- Point
- flutter_app/windows/runner/utils.cpp
- Size
- AtomicI32
- lixh_player_example
- flutter_app/ios/Runner/Assets.xcassets/LaunchImage.imageset/README.md
- CHANGELOG.md
- example/ios/Runner/Assets.xcassets/LaunchImage.imageset/README.md
- LAST_ERROR_MSG
- HostError
- lixh_player_plugin_test.cpp

## God Nodes (most connected - your core abstractions)
1. `SharedTextureBridge` - 83 edges
2. `PlayerSession` - 48 edges
3. `AudioOutput` - 45 edges
4. `Session` - 42 edges
5. `LixhPlayerPlugin` - 28 edges
6. `LixhPlayerPlugin` - 27 edges
7. `AudioOut` - 26 edges
8. `LixhPlayerEngine` - 21 edges
9. `LixhPlayerEngine` - 21 edges
10. `NativeSurface` - 21 edges

## Surprising Connections (you probably didn't know these)
- `RegisterPlugins()` --calls--> `LixhPlayerPluginCApiRegisterWithRegistrar()`  [INFERRED]
  flutter_app/windows/flutter/generated_plugin_registrant.cc → packages/lixh_player/windows/lixh_player_plugin_c_api.cpp
- `wWinMain()` --calls--> `CreateAndAttachConsole()`  [INFERRED]
  flutter_app/windows/runner/main.cpp → flutter_app/windows/runner/utils.cpp
- `wWinMain()` --calls--> `CreateAndAttachConsole()`  [INFERRED]
  packages/lixh_player/example/windows/runner/main.cpp → packages/lixh_player/example/windows/runner/utils.cpp
- `run()` --calls--> `resolve()`  [INFERRED]
  src-tauri/lixh-stream-stack/lixh-stream-resolver/src/bin/lixh_resolve.rs → src-tauri/lixh-stream-stack/lixh-stream-resolver/src/lib.rs
- `wWinMain()` --calls--> `GetCommandLineArguments()`  [INFERRED]
  flutter_app/windows/runner/main.cpp → flutter_app/windows/runner/utils.cpp

## Import Cycles
- None detected.

## Communities (127 total, 56 thin omitted)

### Community 0 - "flutter_app/lib/main.dart"
Cohesion: 0.02
Nodes (69): _abr, _abrBusy, _abrLabel, _appendLog, _appInBackground, _applyLatency, aspect, _audioFrames (+61 more)

### Community 1 - "lixh_player.dart"
Cohesion: 0.15
Nodes (11): createVideoTexture, disposeVideoTexture, getPlatformVersion, getStats, LixhPlayer, open, play, presentTestFrame (+3 more)

### Community 2 - "room_resolve.dart"
Cohesion: 0.03
Nodes (58): args, artist, audioOnly, bitrate, candidates, client, contains, cookies (+50 more)

### Community 3 - "NativeSurface"
Cohesion: 0.17
Nodes (3): AvFrameLite, d3d_device(), NativeSurface

### Community 4 - "AudioOutput"
Cohesion: 0.06
Nodes (29): AudioOutput, base_queue_ms_, buffer_frames_, client_, count_, event_, lifecycle_mu_, max_queue_ (+21 more)

### Community 5 - "FlutterWindow"
Cohesion: 0.15
Nodes (3): FlutterWindow, flutter_controller_, project_

### Community 6 - "example/windows/runner/win32_window.cpp"
Cohesion: 0.16
Nodes (5): Scale(), Win32Window::Win32Window(), WindowClassRegistrar, class_registered_, instance_

### Community 7 - "SharedTextureBridge"
Cohesion: 0.04
Nodes (37): SharedTextureBridge, capture_bgra_, capture_bgra_h_, capture_bgra_ready_, capture_bgra_w_, capture_fmt_, capture_h_, capture_ready_ (+29 more)

### Community 8 - "PlaybackForegroundService.kt"
Cohesion: 0.05
Nodes (8): MainActivity, PlaybackBridge, PlaybackForegroundService, API, FFmpeg layout, Latency roadmap, lixh_player, Platform status

### Community 9 - "RegisterPlugins"
Cohesion: 0.20
Nodes (3): RegisterPlugins(), RegisterPlugins(), LixhPlayerPluginCApiRegisterWithRegistrar()

### Community 10 - "LixhPlayerPlugin"
Cohesion: 0.09
Nodes (10): LixhPlayerPlugin, bridge_, last_notify_ms_, session_, texture_id_, texture_variant_, textures_, ReadDouble() (+2 more)

### Community 11 - "FfmpegRuntime"
Cohesion: 0.08
Nodes (13): FfmpegRuntime, find_prefixed_file(), RuntimeError, MissingLibrary, NotFound, UnsupportedPlatform, RuntimePlatform, MacosArm64 (+5 more)

### Community 12 - "abr_supervisor.dart"
Cohesion: 0.05
Nodes (32): AbrAction, AbrActionKind, AbrSupervisor, _candidates, _consecutiveStalls, _current, currentIndex, _failed (+24 more)

### Community 13 - "FlutterWindow"
Cohesion: 0.15
Nodes (4): FlutterWindow, flutter_controller_, FlutterWindow::FlutterWindow(), project_

### Community 15 - "lixh_player_platform_interface.dart"
Cohesion: 0.06
Nodes (30): audioFrames, audioQueueMs, bytesRead, createVideoTexture, decodeHw, disposeVideoTexture, droppedFrames, getPlatformVersion (+22 more)

### Community 16 - "douyin_expand.dart"
Cohesion: 0.06
Nodes (31): body, client, contains, data, decoded, expandDouyinShortUrl, _fetchRedirectLocation, _fetchWebRid (+23 more)

### Community 17 - "surface.rs"
Cohesion: 0.09
Nodes (24): callback_stub(), lixh_player_create(), lixh_player_destroy(), lixh_player_get_stats(), lixh_player_open(), lixh_player_play(), lixh_player_stop(), LixhCallbacks (+16 more)

### Community 18 - "Session"
Cohesion: 0.08
Nodes (19): Session, audio_, audio_frames_, last_present_, latency_max_ms_, latency_target_ms_, mu_, play_thread_ (+11 more)

### Community 19 - "lixh-stream-resolver/src/lib.rs"
Cohesion: 0.14
Nodes (17): android_http_client(), best_candidate(), bump_retry_extras(), is_douyin_platform(), is_retryable_extract(), looks_like_douyin(), map_media(), map_resolve_error() (+9 more)

### Community 20 - "LixhAudioOutput"
Cohesion: 0.10
Nodes (26): LixhAudioOutput, -dealloc, -ensureQueueRatechannels, -fillBufferqueue, -flush, -init, -primeNeedMsLocked, -pushSamplesframeschannelssampleRate (+18 more)

### Community 21 - "lixh_player_jni.cpp"
Cohesion: 0.15
Nodes (10): Java_com_livecatch_lixh_1player_LixhPlayerPlugin_nativeAttachSurface(), Java_com_livecatch_lixh_1player_LixhPlayerPlugin_nativeCreate(), Java_com_livecatch_lixh_1player_LixhPlayerPlugin_nativeDestroy(), Java_com_livecatch_lixh_1player_LixhPlayerPlugin_nativeDetachSurface(), Java_com_livecatch_lixh_1player_LixhPlayerPlugin_nativeFillStats(), Java_com_livecatch_lixh_1player_LixhPlayerPlugin_nativeOpen(), Java_com_livecatch_lixh_1player_LixhPlayerPlugin_nativeSetLatency(), Java_com_livecatch_lixh_1player_LixhPlayerPlugin_nativeSetVideoEnabled() (+2 more)

### Community 22 - "lixh_player.c"
Cohesion: 0.09
Nodes (24): apply_play_rate(), audio_drift_ms(), choose_hw_format(), decode_packet(), deliver_audio(), deliver_video(), effective_rate_milli(), emit() (+16 more)

### Community 23 - "PlayerSession"
Cohesion: 0.09
Nodes (14): PlayerSession, audio_, bridge_, latency_max_ms_, latency_target_ms_, mu_, on_frame_, play_thread_ (+6 more)

### Community 24 - "playback_keepalive.dart"
Cohesion: 0.15
Nodes (8): _active, bind, _channel, isSupported, PlaybackKeepAlive, start, stop, update

### Community 25 - "douyin_expand.rs"
Cohesion: 0.13
Nodes (13): expand_douyin_input(), expand_douyin_short_url(), fetch_redirect_location(), fetch_web_rid(), live_web_rid_from_location(), looks_like_douyin_short_url(), MOBILE_UA, no_redirect_client() (+5 more)

### Community 26 - "StreamCandidate"
Cohesion: 0.13
Nodes (12): candidate(), StreamCandidate, candidate(), failed_candidate_is_current_candidate(), PlaybackTelemetry, stall_timer_uses_time_since_last_video_progress(), StreamSupervisor, SupervisorAction (+4 more)

### Community 28 - "AudioOut"
Cohesion: 0.11
Nodes (12): AudioOut, base_queue_ms_, ch_, count_, max_queue_ms_, mu_, primed_, r_ (+4 more)

### Community 29 - "lixh_player_test.dart"
Cohesion: 0.11
Nodes (16): MethodChannelLixhPlayer, LixhPlayerPlatform, createVideoTexture, disposeVideoTexture, getPlatformVersion, getStats, initialPlatform, main (+8 more)

### Community 30 - "LixhPlayerEngine"
Cohesion: 0.17
Nodes (15): LixhPlayerEngine, -createVideoTextureWidthheighterror, -dealloc, -disposeVideoTexture, -handleVideoKindwidthheightframe, -initWithTextures, -notifyFrame, -openUrlheaderserror (+7 more)

### Community 31 - "LixhPlayerEngine"
Cohesion: 0.17
Nodes (15): LixhPlayerEngine, -createVideoTextureWidthheighterror, -dealloc, -disposeVideoTexture, -handleVideoKindwidthheightframe, -initWithTextures, -notifyFrame, -openUrlheaderserror (+7 more)

### Community 32 - "app_settings.dart"
Cohesion: 0.10
Nodes (18): abrEnabled, AppSettings, copyWith, hint, _kAbr, _kFlv, _kLatency, _kSnapMigrate (+10 more)

### Community 33 - "settings_sheet.dart"
Cohesion: 0.11
Nodes (13): build, _buildBody, _copy, createState, _draft, initial, initState, logs (+5 more)

### Community 34 - "example/lib/main.dart"
Cohesion: 0.12
Nodes (9): main, build, createState, initPlatformState, initState, _lixhPlayerPlugin, main, _platformVersion (+1 more)

### Community 35 - "package:flutter_test/flutter_test.dart"
Cohesion: 0.17
Nodes (4): main, pick, main, main

### Community 37 - "PlaybackEngine<B>"
Cohesion: 0.23
Nodes (9): EngineError, Backend, NoCandidate, EngineEvent, ReResolve, Started, Stopped, Switched (+1 more)

### Community 38 - "live_input.dart"
Cohesion: 0.12
Nodes (14): 0, best, extractLiveInput, isPasteableLiveClipboard, l, null, score, scoreLiveUrl (+6 more)

### Community 40 - "lixh-playback-engine/src/lib.rs"
Cohesion: 0.15
Nodes (7): EngineState, Idle, Playing, ReResolving, Stopped, PlaybackEngine, unix_ms()

### Community 41 - "Cocoa"
Cohesion: 0.20
Nodes (5): Cocoa, MainFlutterWindow, RunnerTests, FlutterMacOS, MainFlutterWindow

### Community 42 - "native_surface.rs"
Cohesion: 0.22
Nodes (7): NativeFrameKind, D3d11, Software, VideoToolbox, NativeFrameRef, NativeFrameSink, SurfaceRect

### Community 43 - "LixhPixelTexture"
Cohesion: 0.15
Nodes (6): LixhPixelTexture, -presentColorRgbwidthheight, -setPixelBuffer, LixhPixelTexture, -presentColorRgbwidthheight, -setPixelBuffer

### Community 44 - "surface_windows.rs"
Cohesion: 0.03
Nodes (5): AV_PIX_FMT_NV12, AV_PIX_FMT_NV21, AV_PIX_FMT_YUV420P, AV_PIX_FMT_YUVJ420P, LIXH_VIDEO_SOFTWARE

### Community 45 - "Flutter"
Cohesion: 0.24
Nodes (6): Flutter, SceneDelegate, lixh_player, SceneDelegate, UIKit, XCTest

### Community 46 - ".Open"
Cohesion: 0.23
Nodes (6): PcmQueueMsFromChase(), lixh_player_destroy(), lixh_player_set_latency(), lixh_player_set_play_rate(), lixh_player_set_video_sink(), lixh_player_stop()

### Community 47 - "LixhPixelTexture"
Cohesion: 0.18
Nodes (10): LixhPixelTexture, -copyPixelBuffer, -dealloc, -presentColorRgbwidthheight, -setPixelBuffer, LixhPixelTexture, -copyPixelBuffer, -dealloc (+2 more)

### Community 48 - "LixhPlayerEngine"
Cohesion: 0.15
Nodes (11): LixhPlayerEngine, -createVideoTextureWidthheighterror, -disposeVideoTexture, -initWithTextures, -openUrlheaderserror, -presentTestFrameRgberror, -setLatencyTargetMsmaxMs, -setVideoEnabled (+3 more)

### Community 49 - "LixhPlayerEngine"
Cohesion: 0.15
Nodes (11): LixhPlayerEngine, -createVideoTextureWidthheighterror, -disposeVideoTexture, -initWithTextures, -openUrlheaderserror, -presentTestFrameRgberror, -setLatencyTargetMsmaxMs, -setVideoEnabled (+3 more)

### Community 50 - "Stats"
Cohesion: 0.15
Nodes (12): Stats, audio_frames, audio_queue_ms, bytes_read, decode_hw, dropped_frames, lag_ms, last_error (+4 more)

### Community 55 - "RetiredPair"
Cohesion: 0.20
Nodes (6): RetiredPair, frames_left, handles, handles_are_nt, rtvs, textures

### Community 56 - "_PlayerPageState"
Cohesion: 0.24
Nodes (6): PlayerPage, _PlayerPageState, _SettingsSheet, _SettingsSheetState, MyApp, _MyAppState

### Community 57 - "LixhAudioOutput"
Cohesion: 0.22
Nodes (7): LixhAudioOutput, -flush, -pushSamplesframeschannelssampleRate, -queuedMs, -setMaxQueueMs, -start, -stop

### Community 58 - "LixhAudioOutput"
Cohesion: 0.22
Nodes (7): LixhAudioOutput, -flush, -pushSamplesframeschannelssampleRate, -queuedMs, -setMaxQueueMs, -start, -stop

### Community 61 - "example/macos/RunnerTests/RunnerTests.swift"
Cohesion: 0.25
Nodes (3): RunnerTests, RunnerTests, RunnerTests

### Community 63 - "ios/lixh_player/Package.swift"
Cohesion: 0.29
Nodes (4): Foundation, PackageDescription, findRepoRoot(), findRepoRoot()

### Community 65 - "android/bundle_lixh_resolve.sh"
Cohesion: 0.29
Nodes (6): ANDROID_NDK_HOME, ANDROID_NDK_ROOT, AR_aarch64_linux_android, CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER, CC_aarch64_linux_android, bundle_lixh_resolve.sh script

### Community 66 - "StatelessWidget"
Cohesion: 0.29
Nodes (6): _Dock, _Header, _ListenPane, LiveCatchApp, _Stage, _LogViewerPage

### Community 70 - "lixh_player_method_channel.dart"
Cohesion: 0.15
Nodes (11): createVideoTexture, disposeVideoTexture, getPlatformVersion, getStats, methodChannel, open, play, presentTestFrame (+3 more)

### Community 71 - "lixh-stream-supervisor"
Cohesion: 0.50
Nodes (5): lixh-playback-engine, lixh-player-core, lixh-player-host, lixh-stream-resolver, lixh-stream-supervisor

### Community 90 - "Win32Window"
Cohesion: 0.22
Nodes (4): Win32Window, child_content_, quit_on_close_, window_handle_

### Community 91 - ".create"
Cohesion: 0.21
Nodes (5): ensure_clip_siblings(), ensure_host_class(), host_proc(), raise_surface(), set_err()

### Community 92 - "WindowClassRegistrar"
Cohesion: 0.29
Nodes (3): WindowClassRegistrar, class_registered_, instance_

### Community 93 - "package:flutter/services.dart"
Cohesion: 0.33
Nodes (3): channel, main, platform

### Community 97 - "flutter_app/windows/runner/win32_window.cpp"
Cohesion: 0.19
Nodes (5): Win32Window, child_content_, quit_on_close_, Win32Window::Win32Window(), window_handle_

### Community 99 - "LiveCatch"
Cohesion: 0.29
Nodes (6): CI (GitHub Actions), FFmpeg, Layout, LiveCatch, Roadmap (short), Run

### Community 100 - "Agent workflow: Graphify"
Cohesion: 0.33
Nodes (5): Agent workflow: Graphify, Before architecture-level work, Evidence and traceability, Git remote (this machine), Install the upstream tool

### Community 102 - "livecatch_app"
Cohesion: 0.50
Nodes (3): Layout, livecatch_app, Platforms

### Community 106 - "Point"
Cohesion: 0.50
Nodes (3): Point, x, y

### Community 107 - "Size"
Cohesion: 0.50
Nodes (3): Size, height, width

### Community 109 - "Point"
Cohesion: 0.50
Nodes (3): Point, x, y

### Community 113 - "flutter_app/windows/runner/utils.cpp"
Cohesion: 0.12
Nodes (8): wWinMain(), CreateAndAttachConsole(), GetCommandLineArguments(), Utf8FromUtf16(), wWinMain(), CreateAndAttachConsole(), GetCommandLineArguments(), Utf8FromUtf16()

### Community 114 - "Size"
Cohesion: 0.50
Nodes (3): Size, height, width

### Community 124 - "HostError"
Cohesion: 0.12
Nodes (9): CorePlayerAdapter, HostError, AlreadyPlaying, Backend, JoinFailed, NotOpened, NativePlayer, PlayerHost (+1 more)

## Knowledge Gaps
- **547 isolated node(s):** `ANDROID_NDK_HOME`, `ANDROID_NDK_ROOT`, `CC_aarch64_linux_android`, `AR_aarch64_linux_android`, `CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER` (+542 more)
  These have ≤1 connection - possible missing edges or undocumented components. (Counts symbols only; 978 node(s) total have ≤1 connection when file, concept and rationale nodes are included.)
- **56 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `SharedTextureBridge` connect `SharedTextureBridge` to `.HandleVideo`, `shared_texture.cpp`, `.PresentNv12ViaVideoProcessor`, `LixhPlayerPlugin`, `.Descriptor`, `PlayerSession`, `RetiredPair`, `player_session.cpp`, `string`?**
  _High betweenness centrality (0.083) - this node is a cross-community bridge._
- **What connects `ANDROID_NDK_HOME`, `ANDROID_NDK_ROOT`, `CC_aarch64_linux_android` to the rest of the system?**
  _547 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `flutter_app/lib/main.dart` be split into smaller, more focused modules?**
  _Cohesion score 0.024096385542168676 - nodes in this community are weakly interconnected._
- **Why does `LixhNativeFrame` connect `surface.rs` to `NativeSurface`, `surface_windows.rs`?**
  _High betweenness centrality (0.069) - this node is a cross-community bridge._
- **Should `room_resolve.dart` be split into smaller, more focused modules?**
  _Cohesion score 0.031746031746031744 - nodes in this community are weakly interconnected._
- **Why does `PlaybackBridge` connect `PlaybackForegroundService.kt` to `flutter_app/windows/runner/utils.cpp`?**
  _High betweenness centrality (0.056) - this node is a cross-community bridge._
- **Should `AudioOutput` be split into smaller, more focused modules?**
  _Cohesion score 0.05957767722473605 - nodes in this community are weakly interconnected._