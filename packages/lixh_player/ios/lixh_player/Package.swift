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
    "LiveCatch repo root not found. Fetch FFmpeg SDK (ios-arm64) and keep lixh-player-core in-tree.")
}

let repoRoot = findRepoRoot()
let coreInclude = repoRoot
  .appendingPathComponent("src-tauri/lixh-stream-stack/lixh-player-core/include")
  .path
let ffmpegRoot = repoRoot
  .appendingPathComponent("src-tauri/lixh-stream-stack/sdk/ios-arm64")
let ffmpegInclude = ffmpegRoot.appendingPathComponent("include").path
let ffmpegLib = ffmpegRoot.appendingPathComponent("lib").path

let package = Package(
  name: "lixh_player",
  platforms: [
    .iOS("15.0")
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
          "-DLIXH_IOS=1",
        ]),
      ],
      // LiveCatchFfmpeg iOS ships static archives (libav*.a), not dylibs.
      linkerSettings: [
        .linkedLibrary("avformat"),
        .linkedLibrary("avcodec"),
        .linkedLibrary("avutil"),
        .linkedLibrary("swresample"),
        .linkedLibrary("z"),
        .linkedLibrary("bz2"),
        .linkedLibrary("iconv"),
        .linkedFramework("VideoToolbox"),
        .linkedFramework("AudioToolbox"),
        .linkedFramework("CoreMedia"),
        .unsafeFlags([
          "-L\(ffmpegLib)",
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
        .linkedFramework("UIKit"),
        .linkedFramework("VideoToolbox"),
        .unsafeFlags([
          "-L\(ffmpegLib)",
        ]),
      ]
    ),
  ]
)
