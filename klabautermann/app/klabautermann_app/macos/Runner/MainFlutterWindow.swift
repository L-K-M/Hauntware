import Cocoa
import FlutterMacOS
import macos_window_utils
import window_manager

class MainFlutterWindow: NSWindow {
  /// Settings in a window of its own (SettingsWindow.swift).
  private var settingsWindow: SettingsWindowHost?

  /// The checked states of Flutter's PlatformMenuBar items
  /// (MenuChecks.swift).
  private var menuChecks: MenuChecks?

  /// `klabautermann/window`: the toolbar band's state for the Dart side
  /// (ghost_desktop's MacosToolbarBandChannel).
  private var windowChannel: FlutterMethodChannel?

  /// In full screen, or entering it: set on AppKit's will-enter and
  /// will-exit edges, so the toolbar and the Flutter layout switch as a
  /// transition starts rather than after its animation.
  private var inFullScreen = false

  /// The Dart side installs the unified toolbar after launch
  /// (macos_titlebar.dart), possibly after a restored window already
  /// entered full screen, so every toolbar the window receives takes the
  /// current visibility.
  override var toolbar: NSToolbar? {
    didSet { toolbar?.isVisible = !inFullScreen }
  }

  override func awakeFromNib() {
    // The app's windows never tab (this one, and Settings with its own
    // `tabbingMode`); disabling automatic window tabbing stops AppKit from
    // adding tab commands ("Show Tab Bar", etc.) to the menus the Dart
    // side builds (lib/ui/menus/).
    NSWindow.allowsAutomaticWindowTabbing = false

    // Séance's keyboard and accessibility compatibility controller
    // (KlabautermannFlutterViewController.m, docs/SHARED.md): it keeps
    // injected Command shortcuts intact and invalidates native text fields
    // before Flutter destroys their accessibility tree.
    let flutterViewController = KlabautermannFlutterViewController()
    // The integrated titlebar (macos_titlebar.dart): macos_window_utils
    // hosts the Flutter view in its own controller, as in Séance's and
    // Poltergeist's runners. The Flutter controller inside it is still the
    // compatibility controller above.
    let windowUtilsController = MacOSWindowUtilsViewController(
      flutterViewController: flutterViewController)
    self.contentViewController = windowUtilsController
    // The size and place a launch with no saved frame opens at, matching
    // the Linux and Windows runners; restoreMainWindow() replaces it with
    // the saved frame. MainMenu.xib's 800 by 600 is narrower than the
    // desktop shell and would open the phone layout.
    self.setContentSize(NSSize(width: 1280, height: 720))
    self.center()
    // Starts from a standard titlebar; Dart makes it transparent and adds
    // the unified toolbar before the window is first shown.
    MainFlutterWindowManipulator.start(mainFlutterWindow: self)

    settingsWindow = SettingsWindowHost(
      mainWindow: self,
      messenger: flutterViewController.engine.binaryMessenger)

    // `klabautermann/menu_checks` (Poltergeist's MenuChecks.swift): puts
    // the checked state Flutter's menu plugin cannot set on the View
    // menu's pane toggles.
    menuChecks = MenuChecks(
      messenger: flutterViewController.engine.binaryMessenger)

    // Full screen: AppKit keeps a window's toolbar permanently visible in
    // full screen, in an opaque strip of its own above the content. The
    // empty unified toolbar that gives the windowed titlebar its 52 pt
    // band would cover the content's top, so it hides for the duration
    // and the titlebar only slides in with the menu bar.
    // `klabautermann/window` tells the Dart side the band is gone, so it
    // stops reserving it. Notifications rather than delegate methods,
    // because window_manager owns the window's delegate.
    windowChannel = FlutterMethodChannel(
      name: "klabautermann/window",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    windowChannel?.setMethodCallHandler { [weak self] call, result in
      guard let self, call.method == "isToolbarBandVisible" else {
        result(FlutterMethodNotImplemented)
        return
      }
      result(!self.inFullScreen)
    }
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(hideToolbarBandForFullScreen(_:)),
      name: NSWindow.willEnterFullScreenNotification,
      object: self)
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(showToolbarBandLeavingFullScreen(_:)),
      name: NSWindow.willExitFullScreenNotification,
      object: self)

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

  @objc private func hideToolbarBandForFullScreen(_ notification: Notification) {
    setInFullScreen(true)
  }

  @objc private func showToolbarBandLeavingFullScreen(_ notification: Notification) {
    setInFullScreen(false)
  }

  private func setInFullScreen(_ value: Bool) {
    guard value != inFullScreen else { return }
    inFullScreen = value
    toolbar?.isVisible = !value
    windowChannel?.invokeMethod("toolbarBandChanged", arguments: !value)
  }

  /// Keep the window invisible while Dart puts it back where it was closed:
  /// restoreMainWindow() (lib/services/window_state.dart, called from
  /// main.dart before runApp) applies the previous session's frame and
  /// then shows the window, always, even when restoring fails, so the
  /// default-size window never flashes. A second instance, which must not
  /// touch the running one's frame, shows it through
  /// showMainWindowUnrestored() instead. Do not remove this without
  /// removing that contract too.
  override public func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
    super.order(place, relativeTo: otherWin)
    hiddenWindowAtLaunch()
  }
}
