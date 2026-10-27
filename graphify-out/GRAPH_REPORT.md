# Graph Report - liveCatch  (2026-10-27)

## Corpus Check
- 184 files · ~96,220 words
- Verdict: corpus is large enough that graph structure adds value.
- Unclassified: 119 file(s) not represented in the graph (top: (none) 22, .xcconfig 16, .xml 15)

## Summary
- 2413 nodes · 3766 edges · 146 communities (87 shown, 59 thin omitted)
- Extraction: 96% EXTRACTED · 4% INFERRED · 0% AMBIGUOUS · INFERRED: 144 edges (avg confidence: 0.85)
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `fc6db546`
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
- license_api.dart
- LixhPlayerPlugin
- FfmpegRuntime
- abr_supervisor.dart
- FlutterWindow
- LixhPlayerPlugin
- lixh_player_platform_interface.dart
- douyin_expand.dart
- surface.rs
- Session
- ResolvedStream
- LixhAudioOutput
- JNIEnv
- lixh_player.c
- PlayerSession
- playback_keepalive.dart
- expand.rs
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
- lixh-playback-engine/src/lib.rs
- live_input.dart
- shared_texture.cpp
- ab_sign.rs
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
- license_session.dart
- license_sheet.dart
- AppDelegate
- RetiredPair
- _PlayerPageState
- LixhAudioOutput
- LixhAudioOutput
- AppDelegate
- example/macos/RunnerTests/RunnerTests.swift
- AppDelegate
- ios/lixh_player/Package.swift
- bundle_lixh_resolve.sh script
- StatelessWidget
- PlaybackBackend
- license_gate.dart
- Result
- lixh_player_method_channel.dart
- lixh-stream-supervisor
- lixh_player_example/MainActivity.kt
- flutter_app/windows/runner/utils.cpp
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
- 抖音解析 — 上游对齐记录
- kuaishou/parse.rs
- .create
- douyin/mod.rs
- package:flutter/services.dart
- flutter_app/windows/runner/win32_window.cpp
- lixh_resolve_server.rs
- LiveCatch
- Agent workflow: Graphify
- lixh_player/android/build.gradle.kts
- livecatch_app
- xiaohongshu/parse.rs
- xiaohongshu/mod.rs
- kuaishou/mod.rs
- platforms/mod.rs
- throttle_proxy.py
- douyin/parse.rs
- lixh_player_jni.cpp
- enter.rs
- AtomicI32
- lixh_player_example
- flutter_app/ios/Runner/Assets.xcassets/LaunchImage.imageset/README.md
- CHANGELOG.md
- example/ios/Runner/Assets.xcassets/LaunchImage.imageset/README.md
- LAST_ERROR_MSG
- .Open
- Bucket
- lixh_player_plugin_test.cpp
- Remote room resolve (`lixh_resolve_server`)
- LiveCatch 官网
- AppState
- Handler
- rewardplay_config.dart
- http_client.rs
- deploy.sh
- Backend
- resolve_config.dart
- start.sh
- LicenseApiException
- tools/README.md

## God Nodes (most connected - your core abstractions)
1. `SharedTextureBridge` - 83 edges
2. `AudioOut` - 52 edges
3. `PlayerSession` - 50 edges
4. `AudioOutput` - 48 edges
5. `Session` - 46 edges
6. `LixhPlayerPlugin` - 33 edges
7. `LixhPlayerPlugin` - 29 edges
8. `ResolvedStream` - 29 edges
9. `LixhPlayerEngine` - 21 edges
10. `LixhPlayerEngine` - 21 edges

## Surprising Connections (you probably didn't know these)
- `RegisterPlugins()` --calls--> `LixhPlayerPluginCApiRegisterWithRegistrar()`  [INFERRED]
  flutter_app/windows/flutter/generated_plugin_registrant.cc → packages/lixh_player/windows/lixh_player_plugin_c_api.cpp
- `wWinMain()` --calls--> `CreateAndAttachConsole()`  [INFERRED]
  flutter_app/windows/runner/main.cpp → flutter_app/windows/runner/utils.cpp
- `wWinMain()` --calls--> `CreateAndAttachConsole()`  [INFERRED]
  packages/lixh_player/example/windows/runner/main.cpp → packages/lixh_player/example/windows/runner/utils.cpp
- `main()` --calls--> `fetch_web_enter()`  [INFERRED]
  src-tauri/lixh-stream-stack/lixh-stream-resolver/src/bin/dump_douyin_flv.rs → src-tauri/lixh-stream-stack/lixh-stream-resolver/src/platforms/douyin/enter.rs
- `resolve_with_options()` --calls--> `default_registry()`  [INFERRED]
  src-tauri/lixh-stream-stack/lixh-stream-resolver/src/lib.rs → src-tauri/lixh-stream-stack/lixh-stream-resolver/src/platforms/mod.rs

## Import Cycles
- None detected.

## Communities (146 total, 59 thin omitted)

### Community 0 - "flutter_app/lib/main.dart"
Cohesion: 0.02
Nodes (81): _abr, _abrBusy, _abrLabel, _appendLog, _appInBackground, _applyLatency, aspect, _audioFrames (+73 more)

### Community 1 - "lixh_player.dart"
Cohesion: 0.14
Nodes (12): createVideoTexture, disposeVideoTexture, getPlatformVersion, getStats, LixhPlayer, open, play, presentTestFrame (+4 more)

### Community 2 - "room_resolve.dart"
Cohesion: 0.04
Nodes (49): artist, audioOnly, base, bitrate, body, candidates, client, code (+41 more)

### Community 3 - "NativeSurface"
Cohesion: 0.17
Nodes (3): AvFrameLite, d3d_device(), NativeSurface

### Community 4 - "AudioOutput"
Cohesion: 0.06
Nodes (31): AudioOutput, base_queue_ms_, buffer_frames_, client_, count_, event_, last_shrink_, last_underrun_ (+23 more)

### Community 5 - "FlutterWindow"
Cohesion: 0.12
Nodes (4): FlutterWindow, flutter_controller_, FlutterWindow::FlutterWindow(), project_

### Community 6 - "example/windows/runner/win32_window.cpp"
Cohesion: 0.05
Nodes (19): RegisterPlugins(), RegisterPlugins(), EnableFullDpiSupportIfAvailable(), Point, x, y, Scale(), Size (+11 more)

### Community 7 - "SharedTextureBridge"
Cohesion: 0.04
Nodes (37): SharedTextureBridge, capture_bgra_, capture_bgra_h_, capture_bgra_ready_, capture_bgra_w_, capture_fmt_, capture_h_, capture_ready_ (+29 more)

### Community 8 - "PlaybackForegroundService.kt"
Cohesion: 0.06
Nodes (8): MainActivity, PlaybackBridge, PlaybackForegroundService, API, FFmpeg layout, Latency roadmap, lixh_player, Platform status

### Community 9 - "license_api.dart"
Cohesion: 0.04
Nodes (46): activate, _asInt, _baseUrl, boundDeviceCount, boundDeviceId, checkoutContext, _client, code (+38 more)

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
Cohesion: 0.12
Nodes (4): FlutterWindow, flutter_controller_, FlutterWindow::FlutterWindow(), project_

### Community 15 - "lixh_player_platform_interface.dart"
Cohesion: 0.06
Nodes (31): audioFrames, audioQueueMs, bytesRead, createVideoTexture, decodeHw, disposeVideoTexture, droppedFrames, getPlatformVersion (+23 more)

### Community 16 - "douyin_expand.dart"
Cohesion: 0.06
Nodes (31): body, client, contains, data, decoded, expandDouyinShortUrl, _fetchRedirectLocation, _fetchWebRid (+23 more)

### Community 17 - "surface.rs"
Cohesion: 0.05
Nodes (33): callback_stub(), lixh_player_create(), lixh_player_destroy(), lixh_player_get_stats(), lixh_player_open(), lixh_player_play(), lixh_player_stop(), LixhCallbacks (+25 more)

### Community 18 - "Session"
Cohesion: 0.07
Nodes (22): Session, audio_, audio_frames_, buf_h_, buf_w_, last_present_, latency_max_ms_, latency_target_ms_ (+14 more)

### Community 19 - "ResolvedStream"
Cohesion: 0.13
Nodes (7): candidate(), is_douyin_platform(), resolve(), resolve_douyin(), resolve_with_options(), ResolvedStream, ResolveOptions

### Community 20 - "LixhAudioOutput"
Cohesion: 0.09
Nodes (28): LixhAudioOutput, -dealloc, -disposeQueue, -ensureQueueRatechannels, -fillBufferqueue, -flush, -init, -maybeShrinkLocked (+20 more)

### Community 21 - "JNIEnv"
Cohesion: 0.21
Nodes (14): EnsureJavaVm(), Java_com_livecatch_lixh_1player_LixhPlayerPlugin_nativeAttachSurface(), Java_com_livecatch_lixh_1player_LixhPlayerPlugin_nativeCreate(), Java_com_livecatch_lixh_1player_LixhPlayerPlugin_nativeDestroy(), Java_com_livecatch_lixh_1player_LixhPlayerPlugin_nativeDetachSurface(), Java_com_livecatch_lixh_1player_LixhPlayerPlugin_nativeFillStats(), Java_com_livecatch_lixh_1player_LixhPlayerPlugin_nativeLastError(), Java_com_livecatch_lixh_1player_LixhPlayerPlugin_nativeOpen() (+6 more)

### Community 22 - "lixh_player.c"
Cohesion: 0.06
Nodes (62): apply_play_rate(), audio_drift_ms(), audio_worker(), av_skew_ms(), choose_hw_format(), decode_av_packet(), deliver_audio(), deliver_video() (+54 more)

### Community 23 - "PlayerSession"
Cohesion: 0.08
Nodes (15): PlayerSession, audio_, bridge_, latency_max_ms_, latency_target_ms_, listen_play_rate_, mu_, on_frame_ (+7 more)

### Community 24 - "playback_keepalive.dart"
Cohesion: 0.14
Nodes (8): _active, bind, _channel, isSupported, PlaybackKeepAlive, start, stop, update

### Community 25 - "expand.rs"
Cohesion: 0.19
Nodes (11): expand_douyin_input(), expand_douyin_short_url(), fetch_redirect_location(), fetch_web_rid(), live_web_rid_from_location(), MOBILE_UA, parse_reflow_location(), parse_reflow_redirect() (+3 more)

### Community 26 - "StreamCandidate"
Cohesion: 0.13
Nodes (14): ranking_deduplicates_and_prefers_video(), best_candidate(), ranked_candidates(), StreamCandidate, candidate(), failed_candidate_is_current_candidate(), PlaybackTelemetry, stall_timer_uses_time_since_last_video_progress() (+6 more)

### Community 28 - "AudioOut"
Cohesion: 0.06
Nodes (24): AudioOut, aaudio_stream_, backend_, base_queue_ms_, ch_, count_, last_shrink_, last_underrun_ (+16 more)

### Community 29 - "lixh_player_test.dart"
Cohesion: 0.10
Nodes (17): MethodChannelLixhPlayer, LixhPlayerPlatform, createVideoTexture, disposeVideoTexture, getPlatformVersion, getStats, initialPlatform, main (+9 more)

### Community 30 - "LixhPlayerEngine"
Cohesion: 0.17
Nodes (15): LixhPlayerEngine, -createVideoTextureWidthheighterror, -dealloc, -disposeVideoTexture, -handleVideoKindwidthheightframe, -initWithTextures, -notifyFrame, -openUrlheaderserror (+7 more)

### Community 31 - "LixhPlayerEngine"
Cohesion: 0.17
Nodes (15): LixhPlayerEngine, -createVideoTextureWidthheighterror, -dealloc, -disposeVideoTexture, -handleVideoKindwidthheightframe, -initWithTextures, -notifyFrame, -openUrlheaderserror (+7 more)

### Community 32 - "app_settings.dart"
Cohesion: 0.08
Nodes (23): abrEnabled, AppSettings, copyWith, hint, _kAbr, _kFlv, _kLatency, _kListenRate (+15 more)

### Community 33 - "settings_sheet.dart"
Cohesion: 0.06
Nodes (25): build, _buildBody, _copy, createState, _draft, foam, initial, initState (+17 more)

### Community 34 - "example/lib/main.dart"
Cohesion: 0.11
Nodes (11): main, build, createState, initPlatformState, initState, _lixhPlayerPlugin, main, MyApp (+3 more)

### Community 35 - "package:flutter_test/flutter_test.dart"
Cohesion: 0.12
Nodes (5): main, pick, main, main, main

### Community 37 - "lixh-playback-engine/src/lib.rs"
Cohesion: 0.11
Nodes (16): EngineError, Backend, NoCandidate, EngineEvent, ReResolve, Started, Stopped, Switched (+8 more)

### Community 38 - "live_input.dart"
Cohesion: 0.12
Nodes (14): 0, best, extractLiveInput, isPasteableLiveClipboard, l, null, score, scoreLiveUrl (+6 more)

### Community 40 - "ab_sign.rs"
Cohesion: 0.11
Nodes (30): ab_sign(), ENCODING_TABLES, ff_j(), gener_random(), generate_random_str(), generate_rc4_bb_str(), generate_rc4_bb_str_with_time(), get_long_int() (+22 more)

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
Cohesion: 0.24
Nodes (3): PcmQueueMsFromChase(), lixh_player_report_audio_queue_ms(), lixh_player_set_headers()

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
Cohesion: 0.14
Nodes (12): Stats, audio_frames, audio_queue_ms, bytes_read, decode_hw, dropped_frames, lag_ms, last_error (+4 more)

### Community 51 - "license_session.dart"
Cohesion: 0.06
Nodes (29): activate, active, _applyBind, boundDeviceCount, code, copyWith, deviceId, expiresAt (+21 more)

### Community 52 - "license_sheet.dart"
Cohesion: 0.06
Nodes (31): LicenseApi, LicenseCheckoutContext, LicensePackage, _activate, api, build, _busy, _codeCtrl (+23 more)

### Community 55 - "RetiredPair"
Cohesion: 0.20
Nodes (6): RetiredPair, frames_left, handles, handles_are_nt, rtvs, textures

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

### Community 66 - "StatelessWidget"
Cohesion: 0.17
Nodes (11): _EntitlementCard, _PackageTile, _Dock, _Header, _LineSheet, _ListenPane, LiveCatchApp, _Stage (+3 more)

### Community 68 - "license_gate.dart"
Cohesion: 0.06
Nodes (27): action, allowed, any, blocked, body, ensureLicenseForPlayback, false, foam (+19 more)

### Community 69 - "Result"
Cohesion: 0.16
Nodes (6): file_of(), is_bare(), main(), walk(), main(), run()

### Community 70 - "lixh_player_method_channel.dart"
Cohesion: 0.15
Nodes (12): createVideoTexture, disposeVideoTexture, getPlatformVersion, getStats, methodChannel, open, play, presentTestFrame (+4 more)

### Community 71 - "lixh-stream-supervisor"
Cohesion: 0.50
Nodes (5): lixh-playback-engine, lixh-player-core, lixh-player-host, lixh-stream-resolver, lixh-stream-supervisor

### Community 73 - "flutter_app/windows/runner/utils.cpp"
Cohesion: 0.12
Nodes (8): wWinMain(), CreateAndAttachConsole(), GetCommandLineArguments(), Utf8FromUtf16(), wWinMain(), CreateAndAttachConsole(), GetCommandLineArguments(), Utf8FromUtf16()

### Community 89 - "抖音解析 — 上游对齐记录"
Cohesion: 0.07
Nodes (24): 上游定位, 上游来源（按优先级）, 与 streamget 的刻意差异, 协议摘要, 复查清单, 抖音解析 — 上游对齐记录, 上游定位线索（复查时用）, 上游来源（按优先级） (+16 more)

### Community 90 - "kuaishou/parse.rs"
Cohesion: 0.14
Nodes (18): canonical_room_url(), extract_representations(), INITIAL_STATE_RE, LIVE_STREAM_FRAGMENT_RE, looks_like_kuaishou_host(), looks_like_kuaishou_live_url(), offline_resolved(), parse_play_list_json() (+10 more)

### Community 91 - ".create"
Cohesion: 0.21
Nodes (5): ensure_clip_siblings(), ensure_host_class(), host_proc(), raise_surface(), set_err()

### Community 92 - "douyin/mod.rs"
Cohesion: 0.12
Nodes (10): looks_like_douyin_short_url(), no_redirect_client(), DouyinBackend, is_rid_token(), LIVE_RID_RE, looks_like_douyin_url(), parse_http_url(), path_web_rid() (+2 more)

### Community 93 - "package:flutter/services.dart"
Cohesion: 0.33
Nodes (3): channel, main, platform

### Community 97 - "flutter_app/windows/runner/win32_window.cpp"
Cohesion: 0.07
Nodes (16): EnableFullDpiSupportIfAvailable(), Point, x, y, Scale(), Size, height, width (+8 more)

### Community 98 - "lixh_resolve_server.rs"
Cohesion: 0.14
Nodes (7): authorize(), ErrorBody, format_resolve_err(), health(), LICENSE_CHECK_UNAVAILABLE, resolve_handler(), ResolveRequest

### Community 99 - "LiveCatch"
Cohesion: 0.29
Nodes (6): CI (GitHub Actions), FFmpeg, Layout, LiveCatch, Roadmap (short), Run

### Community 100 - "Agent workflow: Graphify"
Cohesion: 0.33
Nodes (5): Agent workflow: Graphify, Before architecture-level work, Evidence and traceability, Git remote (this machine), Install the upstream tool

### Community 102 - "livecatch_app"
Cohesion: 0.50
Nodes (3): Layout, livecatch_app, Platforms

### Community 103 - "xiaohongshu/parse.rs"
Cohesion: 0.19
Nodes (12): ANCHOR_NAME_RE, INITIAL_STATE_RE, live_state_builds_http_candidates(), MOBILE_UA, offline_resolved(), playback_headers(), PROFILE_ID_RE, query_param() (+4 more)

### Community 104 - "xiaohongshu/mod.rs"
Cohesion: 0.14
Nodes (5): expand_xhs_short_url(), mobile_headers(), XiaohongshuBackend, is_xhs_short_url(), looks_like_xiaohongshu_host()

### Community 106 - "kuaishou/mod.rs"
Cohesion: 0.18
Nodes (5): expand_kuaishou_short_url(), fetch_user_living(), KuaishouBackend, pc_headers(), scrape_principal_from_html()

### Community 107 - "platforms/mod.rs"
Cohesion: 0.24
Nodes (9): default_registry(), douyin_claimed(), kuaishou_claimed(), PlatformBackend, registry_order_natives_only(), resolve_with_registry(), ResolveCtx, unknown_host_unmatched() (+1 more)

### Community 109 - "throttle_proxy.py"
Cohesion: 0.17
Nodes (3): main(), main(), Server

### Community 113 - "douyin/parse.rs"
Cohesion: 0.25
Nodes (10): extract_flv_map(), merge_bare_flv(), merge_origin_flv(), parse_stream_data(), parses_minimal_live_room(), playback_headers(), playback_url(), quality_bitrate() (+2 more)

### Community 114 - "lixh_player_jni.cpp"
Cohesion: 0.13
Nodes (4): AAudioApi, lib, AAudioStreamBuilderStruct, AAudioStreamStruct

### Community 117 - "enter.rs"
Cohesion: 0.26
Nodes (9): enter_once(), fetch_ttwid(), fetch_web_enter(), PC_UA, query_encoding_stable(), resolve_ttwid_cookie(), serde_urlencoded(), TTWID_REGISTER (+1 more)

### Community 124 - ".Open"
Cohesion: 0.18
Nodes (3): lixh_player_create(), lixh_player_set_latency(), lixh_player_set_play_rate()

### Community 125 - "Bucket"
Cohesion: 0.20
Nodes (3): Bucket, build_opener(), Handler

### Community 129 - "Remote room resolve (`lixh_resolve_server`)"
Cohesion: 0.29
Nodes (6): Client, Deploy (on the server), Endpoints (public), Remote room resolve (`lixh_resolve_server`), Start / recover (from your laptop), Why it looks “down” after Rewardplay deploy

### Community 130 - "LiveCatch 官网"
Cohesion: 0.29
Nodes (6): LiveCatch 官网, 上线前要替换, 内容边界, 本地预览, 设计说明, 部署

### Community 131 - "AppState"
Cohesion: 0.33
Nodes (4): AppState, license_payload_active(), LicenseGate, RateLimiter

### Community 133 - "rewardplay_config.dart"
Cohesion: 0.40
Nodes (4): base, kRewardPlayBaseUrl, kRewardPlayIntegrationToken, kRewardPlayProjectCode

### Community 134 - "http_client.rs"
Cohesion: 0.90
Nodes (3): android_http_client(), build_no_redirect_client(), build_resolve_client()

### Community 136 - "deploy.sh"
Cohesion: 0.50
Nodes (3): RUSTUP_DIST_SERVER, RUSTUP_UPDATE_ROOT, deploy.sh script

### Community 137 - "Backend"
Cohesion: 0.50
Nodes (4): Backend, AAudio, None, OpenSL

## Knowledge Gaps
- **721 isolated node(s):** `RUSTUP_DIST_SERVER`, `RUSTUP_UPDATE_ROOT`, `AbrActionKind`, `AbrAction`, `kind` (+716 more)
  These have ≤1 connection - possible missing edges or undocumented components. (Counts symbols only; 1260 node(s) total have ≤1 connection when file, concept and rationale nodes are included.)
- **59 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `SharedTextureBridge` connect `SharedTextureBridge` to `.HandleVideo`, `shared_texture.cpp`, `LixhPlayerPlugin`, `.AttachTexture`, `.Descriptor`, `PlayerSession`, `RetiredPair`, `.PresentNv12ViaVideoProcessor`, `string`?**
  _High betweenness centrality (0.179) - this node is a cross-community bridge._
- **What connects `RUSTUP_DIST_SERVER`, `RUSTUP_UPDATE_ROOT`, `AbrActionKind` to the rest of the system?**
  _721 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `flutter_app/lib/main.dart` be split into smaller, more focused modules?**
  _Cohesion score 0.022222222222222223 - nodes in this community are weakly interconnected._
- **Why does `LixhNativeFrame` connect `surface.rs` to `NativeSurface`, `surface_windows.rs`?**
  _High betweenness centrality (0.099) - this node is a cross-community bridge._
- **Should `lixh_player.dart` be split into smaller, more focused modules?**
  _Cohesion score 0.14285714285714285 - nodes in this community are weakly interconnected._
- **Why does `Win32Window` connect `flutter_app/windows/runner/win32_window.cpp` to `windows`?**
  _High betweenness centrality (0.053) - this node is a cross-community bridge._
- **Should `room_resolve.dart` be split into smaller, more focused modules?**
  _Cohesion score 0.037037037037037035 - nodes in this community are weakly interconnected._