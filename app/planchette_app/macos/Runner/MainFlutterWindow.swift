import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    // Document tabs belong to the shell; AppKit must not offer a second tab bar.
    NSWindow.allowsAutomaticWindowTabbing = false
    tabbingMode = .disallowed
    let controller = PlanchetteFlutterViewController()
    let windowFrame = frame
    contentViewController = controller
    setFrame(windowFrame, display: true)
    RegisterGeneratedPlugins(registry: controller)
    (NSApplication.shared.delegate as? AppDelegate)?.installDocumentChannel(
      messenger: controller.engine.binaryMessenger
    )
    super.awakeFromNib()
  }
}
