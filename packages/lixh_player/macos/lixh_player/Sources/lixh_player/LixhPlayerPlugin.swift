import Cocoa
import FlutterMacOS

public class LixhPlayerPlugin: NSObject, FlutterPlugin {
  private var engine: LixhPlayerEngine?

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "lixh_player", binaryMessenger: registrar.messenger)
    let instance = LixhPlayerPlugin()
    instance.engine = LixhPlayerEngine(textures: registrar.textures)
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    if call.method == "getPlatformVersion" {
      result("macOS " + ProcessInfo.processInfo.operatingSystemVersionString)
      return
    }
    guard let engine else {
      result(
        FlutterError(
          code: "no_engine", message: "plugin not registered", details: nil))
      return
    }
    switch call.method {
    case "createVideoTexture":
      let args = call.arguments as? [String: Any]
      let w = (args?["width"] as? NSNumber)?.intValue ?? 1280
      let h = (args?["height"] as? NSNumber)?.intValue ?? 720
      do {
        let map = try engine.createVideoTextureWidth(Int32(w), height: Int32(h))
        result(map)
      } catch {
        result(
          FlutterError(
            code: "texture_failed", message: error.localizedDescription, details: nil))
      }
    case "presentTestFrame":
      let args = call.arguments as? [String: Any]
      let r = (args?["r"] as? NSNumber)?.floatValue ?? 0.1
      let g = (args?["g"] as? NSNumber)?.floatValue ?? 0.5
      let b = (args?["b"] as? NSNumber)?.floatValue ?? 0.9
      do {
        try engine.presentTestFrameR(r, g: g, b: b)
        result(true)
      } catch {
        result(
          FlutterError(
            code: "present_failed", message: error.localizedDescription, details: nil))
      }
    case "open":
      let args = call.arguments as? [String: Any]
      guard let url = args?["url"] as? String, !url.isEmpty else {
        result(FlutterError(code: "bad_args", message: "url required", details: nil))
        return
      }
      let headers = args?["headers"] as? String
      do {
        try engine.openUrl(url, headers: headers)
        result(true)
      } catch {
        result(
          FlutterError(
            code: "open_failed", message: error.localizedDescription, details: nil))
      }
    case "play":
      do {
        try engine.startPlayback()
        result(true)
      } catch {
        result(
          FlutterError(
            code: "play_failed", message: error.localizedDescription, details: nil))
      }
    case "stop":
      // Join play thread off the Flutter platform/UI thread (merged on macOS).
      DispatchQueue.global(qos: .userInitiated).async {
        engine.stop()
        DispatchQueue.main.async { result(true) }
      }
    case "setVideoEnabled":
      let args = call.arguments as? [String: Any]
      let enabled = (args?["enabled"] as? Bool) ?? false
      engine.setVideoEnabled(enabled)
      result(true)
    case "setLatency":
      let args = call.arguments as? [String: Any]
      let target = (args?["targetMs"] as? NSNumber)?.intValue
      let maxv = (args?["maxMs"] as? NSNumber)?.intValue
      guard let target, let maxv else {
        result(FlutterError(code: "bad_args", message: "targetMs and maxMs required", details: nil))
        return
      }
      engine.setLatencyTargetMs(Int32(target), maxMs: Int32(maxv))
      result(true)
    case "setPlayRate":
      // Listen catch-up rate is Android/FFmpeg-path only for now.
      result(true)
    case "getStats":
      result(engine.stats())
    case "disposeVideoTexture":
      engine.disposeVideoTexture()
      result(true)
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}
