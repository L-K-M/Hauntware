import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  /// Closing the window ends its sessions and hides it; Séance keeps
  /// running in the Dock, as Terminal and Mail do, and reopens the window
  /// from there (`applicationShouldHandleReopen`). The Dart side owns the
  /// close (`WindowStateService`).
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    if !flag, let window = MainFlutterWindow.shared {
      window.commands?.run("showMainWindow")
      return false
    }
    return true
  }

  func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
    MainFlutterWindow.shared?.commands?.dockMenu()
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
