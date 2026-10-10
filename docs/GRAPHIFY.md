# LiveCatch Graphify Architecture Graph

> Generated from the repository tree and source entry points on 2026-10-10. This is a source-grounded architecture graph, not a runtime-generated call graph. Update it when module boundaries or data flow change.

## System context

```mermaid
flowchart TB
  User[User / Live room URL]

  subgraph Flutter["Flutter-first app"]
    UI["flutter_app/lib/main.dart\nPlayerPage + UI state"]
    Room["flutter_app/lib/room_resolve.dart\nRoom URL resolution"]
    ABR["flutter_app/lib/abr_supervisor.dart\nAdaptive bitrate / recovery"]
    Plugin["packages/lixh_player/lib\nDart plugin API"]
  end

  subgraph NativePlugin["lixh_player platform implementations"]
    Win["Windows C++ plugin\nplayer_session / shared_texture"]
    Apple["macOS + iOS Swift/Obj-C\nplayer engine / pixel texture / audio"]
    Android["Android Kotlin + JNI\nMediaCodec / SurfaceTexture path"]
  end

  subgraph Tauri["Tauri desktop / shared stream stack"]
    WebUI["src.js + style.css\nTauri frontend"]
    Commands["src-tauri/src/main.rs\nTauri commands + live task lifecycle"]
    Player["src-tauri/src/player/mod.rs\nPlayback integration"]
    Resolver["lixh-stream-resolver\nplatform extractor + candidate ranking"]
    Engine["lixh-playback-engine\nbackend orchestration"]
    Supervisor["lixh-stream-supervisor\ntelemetry + switch / re-resolve policy"]
    Core["lixh-player-core\nshared C player core + runtime/surface"]
    Host["lixh-player-host\nhost integration"]
  end

  FFmpeg["LiveCatchFfmpeg repository\nplatform SDK / runtime artifacts"]
  CI["GitHub Actions\nFlutter / Tauri / FFmpeg consume checks"]

  User --> UI
  UI --> Room
  UI --> ABR
  UI --> Plugin
  Plugin --> Win
  Plugin --> Apple
  Plugin --> Android

  User --> WebUI
  WebUI -->|invoke / events| Commands
  Commands --> Player
  Commands --> Resolver
  Player --> Engine
  Engine --> Resolver
  Engine --> Supervisor
  Engine --> Core
  Engine --> Host
  FFmpeg -. fetch scripts / binaries .-> Core
  FFmpeg -. SDK and runtime artifacts .-> Tauri
  CI -. validates .-> Flutter
  CI -. validates .-> Tauri
```

## Main runtime flows

### Flutter playback

```mermaid
sequenceDiagram
  participant U as User
  participant UI as PlayerPage
  participant R as room_resolve.dart
  participant A as abr_supervisor.dart
  participant P as LixhPlayer Dart API
  participant N as Native platform plugin

  U->>UI: Enter room / stream URL
  UI->>R: Resolve room URL when required
  R-->>UI: Stream URL and metadata
  UI->>P: Create texture / open / start playback
  P->>N: Platform channel / FFI bridge
  N-->>UI: Texture and playback statistics
  loop Periodic health sampling
    UI->>P: Read playback stats
    P->>N: Query native telemetry
    N-->>UI: Frames, bytes, lag and presentation stats
    UI->>A: Report stalls / candidate health
    A-->>UI: Keep, switch candidate or re-resolve
  end
```

### Tauri / Rust playback stack

```mermaid
sequenceDiagram
  participant UI as src.js
  participant App as src-tauri main.rs
  participant R as Stream resolver
  participant E as Playback engine
  participant S as Stream supervisor
  participant B as Native playback backend

  UI->>App: Start live task (Tauri invoke)
  App->>R: Resolve room URL / extract candidates
  R-->>App: Metadata + ranked StreamCandidate list
  App->>E: Start playback with candidates
  E->>B: Stop previous session, open candidate, start
  loop Telemetry polling
    E->>B: Read playback telemetry
    B-->>E: Playback health
    E->>S: Observe telemetry
    alt Candidate switch
      S-->>E: Switch(index, reason)
      E->>B: Open and start selected candidate
    else Re-resolve needed
      S-->>E: ReResolve(reason)
      E-->>App: Re-resolution event
      App-->>UI: Live event / status update
    else Healthy
      S-->>E: Keep
    end
  end
```

## Component index

| Component | Responsibility | Key source paths |
|---|---|---|
| Flutter UI | Main Flutter application, player lifecycle, telemetry polling and recovery coordination | `flutter_app/lib/main.dart` |
| Flutter room resolution | Resolves room URLs for the Flutter path | `flutter_app/lib/room_resolve.dart` |
| Flutter ABR | Chooses adaptive bitrate recovery actions from playback health | `flutter_app/lib/abr_supervisor.dart` |
| Dart plugin interface | Stable Dart-facing player API and platform abstraction | `packages/lixh_player/lib/` |
| Windows plugin | Windows native playback session, audio and shared-texture presentation | `packages/lixh_player/windows/` |
| Apple plugin | macOS/iOS playback engine, audio output and pixel texture | `packages/lixh_player/macos/`, `packages/lixh_player/ios/` |
| Android plugin | Android plugin bridge and JNI/native playback integration | `packages/lixh_player/android/` |
| Tauri frontend | Desktop UI, command invocation, event consumption and native-window docking | `src.js`, `style.css` |
| Tauri command layer | Live task generations, lifecycle, command handlers and event emission | `src-tauri/src/main.rs`, `src-tauri/src/player/mod.rs` |
| Stream resolver | Platform extraction, metadata mapping, deduplication and candidate ranking | `src-tauri/lixh-stream-stack/lixh-stream-resolver/src/lib.rs` |
| Playback engine | Opens/starts/stops candidates and reacts to supervisor decisions | `src-tauri/lixh-stream-stack/lixh-playback-engine/src/lib.rs` |
| Stream supervisor | Evaluates telemetry and returns keep/switch/re-resolve decisions | `src-tauri/lixh-stream-stack/lixh-stream-supervisor/src/lib.rs` |
| Shared player core | Shared C playback core, runtime and native surface support | `src-tauri/lixh-stream-stack/lixh-player-core/` |
| Player host | Host-side integration boundary for the player stack | `src-tauri/lixh-stream-stack/lixh-player-host/src/lib.rs` |
| FFmpeg delivery | Downloads SDK/runtime artifacts for supported platform targets | `src-tauri/lixh-stream-stack/scripts/` |
| CI verification | Flutter analysis/tests, Tauri platform checks and FFmpeg artifact-consumption checks | `.github/workflows/` |

## Important boundaries and follow-up checks

- The repository currently contains both a Flutter-first application and a Tauri frontend/backend path. Treat them as distinct application entry paths that share concepts and parts of the native playback stack; do not assume every feature is implemented identically in both.
- `packages/lixh_player` is a Flutter plugin with platform-specific implementations. Changes to its Dart interface may require synchronized platform implementations and tests.
- The Rust resolver ranks and deduplicates candidates; the playback engine delegates health decisions to the supervisor. Keep candidate ordering, switch behavior and re-resolution semantics covered by tests.
- FFmpeg SDK/runtime artifacts are fetched from the separate `LiveCatchFfmpeg` repository. Build success depends on the correct platform artifacts being available.
- The diagram describes confirmed module-level relationships. Some lower-level native calls and all runtime paths have not been exhaustively traced in this document.
