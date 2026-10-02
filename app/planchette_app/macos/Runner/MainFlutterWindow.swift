import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  /// More document windows on this engine (DocumentWindows.swift).
  private var documentWindows: DocumentWindowsHost?

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
    documentWindows = DocumentWindowsHost(
      mainWindow: self,
      engine: controller.engine
    )
    super.awakeFromNib()
  }

  /// Every extra document window closes with this one, so closing the app's
  /// window still leaves no window open and quits the app
  /// (AppDelegate.applicationShouldTerminateAfterLastWindowClosed). With
  /// other document windows open, the close button only hides this window
  /// (DesktopWindow), so this runs as the app quits.
  override func close() {
    documentWindows?.closeAll()
    super.close()
  }
}
