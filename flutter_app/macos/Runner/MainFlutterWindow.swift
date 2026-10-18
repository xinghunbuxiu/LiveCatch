import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController
    // Phone-sized window (iPhone logical points). Video letterboxes inside it.
    let phone = NSSize(width: 390, height: 844)
    setContentSize(phone)
    contentMinSize = NSSize(width: 360, height: 700)
    if let screen = screen ?? NSScreen.main {
      let visible = screen.visibleFrame
      let frame = frameRect(forContentRect: NSRect(origin: .zero, size: phone))
      setFrameOrigin(NSPoint(
        x: visible.midX - frame.width / 2,
        y: visible.midY - frame.height / 2
      ))
    }

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
