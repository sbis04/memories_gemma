import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController

    // Don't restore the previous frame; always open large and centered on the
    // main display — this is a lean-back, TV-style gallery.
    self.isRestorable = false
    if let screen = NSScreen.main {
      let visible = screen.visibleFrame
      let width = min(1600, visible.width)
      let height = min(1000, visible.height)
      let x = visible.minX + (visible.width - width) / 2
      let y = visible.minY + (visible.height - height) / 2
      self.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
    }
    // Become the key window so D-pad / keyboard input is delivered immediately.
    self.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
