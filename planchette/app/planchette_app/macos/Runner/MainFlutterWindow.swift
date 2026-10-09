import Cocoa
import FlutterMacOS
import window_manager

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

  /// Keep the window invisible while Dart puts it back where it was closed:
  /// DesktopWindow.initialize() (main.dart, before the first frame) applies
  /// the previous session's frame and then shows the window — always, even
  /// when restoring fails — so the storyboard's default-size window never
  /// flashes. Only this window launches hidden; document windows the runner
  /// opens later appear on request. Do not remove this without removing
  /// that contract too.
  override public func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
    super.order(place, relativeTo: otherWin)
    hiddenWindowAtLaunch()
  }
}
