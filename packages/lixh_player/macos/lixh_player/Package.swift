// swift-tools-version: 5.9
import Foundation
import PackageDescription

func findRepoRoot() -> URL {
  let fm = FileManager.default
  var starts: [URL] = [
    URL(fileURLWithPath: #filePath).deletingLastPathComponent()
  ]
  starts.append(URL(fileURLWithPath: fm.currentDirectoryPath))
  for start in starts {
    var dir = start
    for _ in 0..<14 {
      let marker = dir.appendingPathComponent(
        "src-tauri/lixh-stream-stack/lixh-player-core/include/lixh_player.h")
      if fm.fileExists(atPath: marker.path) {
        return dir
      }
      let parent = dir.deletingLastPathComponent()
      if parent.path == dir.path { break }
      dir = parent
    }
  }
  fatalError(
    "LiveCatch repo root not found. Fetch FFmpeg SDK and keep lixh-player-core in-tree.")
}

#if arch(arm64)
let ffmpegPlat = "macos-arm64"
#else
let ffmpegPlat = "macos-x64"
#endif

let repoRoot = findRepoRoot()
let coreInclude = repoRoot
  .appendingPathComponent("src-tauri/lixh-stream-stack/lixh-player-core/include")
  .path
let ffmpegRoot = repoRoot
  .appendingPathComponent("src-tauri/lixh-stream-stack/sdk/\(ffmpegPlat)")
let ffmpegInclude = ffmpegRoot.appendingPathComponent("include").path
let ffmpegLib = ffmpegRoot.appendingPathComponent("lib").path

let package = Package(
  name: "lixh_player",
  platforms: [
    .macOS("12.0")
  ],
  products: [
    .library(name: "lixh-player", targets: ["lixh_player"])
  ],
  dependencies: [
    .package(name: "FlutterFramework", path: "../FlutterFramework")
  ],
  targets: [
    .target(
      name: "lixh_player_corec",
      publicHeadersPath: "include",
      cSettings: [
        .headerSearchPath("include"),
        .unsafeFlags([
          "-I\(coreInclude)",
          "-I\(ffmpegInclude)",
          "-std=c11",
          "-DLIXH_MACOS=1",
        ]),
      ],
      linkerSettings: [
        .linkedLibrary("avformat"),
        .linkedLibrary("avcodec"),
        .linkedLibrary("avutil"),
        .linkedLibrary("swresample"),
        .unsafeFlags([
          "-L\(ffmpegLib)",
          "-Wl,-rpath,\(ffmpegLib)",
        ]),
      ]
    ),
    .target(
      name: "lixh_player",
      dependencies: [
        "lixh_player_corec",
        .product(name: "FlutterFramework", package: "FlutterFramework"),
      ],
      exclude: ["PrivacyInfo.xcprivacy"],
      cSettings: [
        .headerSearchPath("include"),
        .unsafeFlags([
          "-I\(coreInclude)",
          "-I\(ffmpegInclude)",
          "-fobjc-arc",
        ]),
      ],
      linkerSettings: [
        .linkedFramework("AudioToolbox"),
        .linkedFramework("AVFoundation"),
        .linkedFramework("CoreMedia"),
        .linkedFramework("CoreVideo"),
        .linkedFramework("Cocoa"),
        .unsafeFlags([
          "-L\(ffmpegLib)",
          "-Wl,-rpath,\(ffmpegLib)",
        ]),
      ]
    ),
  ]
)
