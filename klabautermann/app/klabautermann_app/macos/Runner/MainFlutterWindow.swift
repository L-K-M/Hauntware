import Cocoa
import FlutterMacOS

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
}
