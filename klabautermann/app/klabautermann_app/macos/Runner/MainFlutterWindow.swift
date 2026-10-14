import Cocoa
import FlutterMacOS
import window_manager

class MainFlutterWindow: NSWindow {
  /// Settings in a window of its own (SettingsWindow.swift).
  private var settingsWindow: SettingsWindowHost?

  override func awakeFromNib() {
    // Séance's keyboard and accessibility compatibility controller
    // (KlabautermannFlutterViewController.m, docs/SHARED.md): it keeps
    // injected Command shortcuts intact and invalidates native text fields
    // before Flutter destroys their accessibility tree.
    let flutterViewController = KlabautermannFlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    settingsWindow = SettingsWindowHost(
      mainWindow: self,
      messenger: flutterViewController.engine.binaryMessenger)

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }

  /// The Settings window closes with this one, so closing the app's window
  /// still leaves no window open and quits the app
  /// (AppDelegate.applicationShouldTerminateAfterLastWindowClosed).
  override func close() {
    settingsWindow?.close()
    super.close()
  }

  /// Keep the window invisible while Dart puts it back where it was closed:
  /// restoreMainWindow() (lib/services/window_state.dart, called from
  /// main.dart before runApp) applies the previous session's frame and
  /// then shows the window, always, even when restoring fails, so the
  /// default-size window never flashes. Do not remove this without
  /// removing that contract too.
  override public func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
    super.order(place, relativeTo: otherWin)
    hiddenWindowAtLaunch()
  }
}
