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
      var err: NSError?
      if let map = engine.createVideoTextureWidth(Int32(w), height: Int32(h), failure: &err) {
        result(map)
      } else {
        result(
          FlutterError(
            code: "texture_failed", message: err?.localizedDescription, details: nil))
      }
    case "presentTestFrame":
      let args = call.arguments as? [String: Any]
      let r = (args?["r"] as? NSNumber)?.floatValue ?? 0.1
      let g = (args?["g"] as? NSNumber)?.floatValue ?? 0.5
      let b = (args?["b"] as? NSNumber)?.floatValue ?? 0.9
      var err: NSError?
      if engine.presentTestFrameR(r, g: g, b: b, failure: &err) {
        result(true)
      } else {
        result(
          FlutterError(
            code: "present_failed", message: err?.localizedDescription, details: nil))
      }
    case "open":
      let args = call.arguments as? [String: Any]
      guard let url = args?["url"] as? String, !url.isEmpty else {
        result(FlutterError(code: "bad_args", message: "url required", details: nil))
        return
      }
      let headers = args?["headers"] as? String
      var err: NSError?
      if engine.openUrl(url, headers: headers, failure: &err) {
        result(true)
      } else {
        result(
          FlutterError(
            code: "open_failed", message: err?.localizedDescription, details: nil))
      }
    case "play":
      var err: NSError?
      if engine.startPlayback(&err) {
        result(true)
      } else {
        result(
          FlutterError(
            code: "play_failed", message: err?.localizedDescription, details: nil))
      }
    case "stop":
      engine.stop()
      result(true)
    case "setVideoEnabled":
      let args = call.arguments as? [String: Any]
      let enabled = (args?["enabled"] as? Bool) ?? false
      engine.setVideoEnabled(enabled)
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
