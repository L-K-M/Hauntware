import Cocoa
import FlutterMacOS
import UniformTypeIdentifiers
import macos_window_utils
import window_manager

class MainFlutterWindow: NSWindow {
  private var menuChannel: FlutterMethodChannel?
  private var filesChannel: FlutterMethodChannel?
  private var bookmarksChannel: FlutterMethodChannel?
  private var windowChannel: FlutterMethodChannel?

  /// In full screen, or entering it: set on AppKit's will-enter and
  /// will-exit edges, so the toolbar and the Flutter layout switch as a
  /// transition starts rather than after its animation.
  private var inFullScreen = false

  /// The Dart side installs the unified toolbar after launch
  /// (macos_titlebar.dart), possibly after a restored window already
  /// entered full screen, so every toolbar the window receives takes the
  /// current visibility.

  /// Settings in a window of its own (SettingsWindow.swift).
  private var settingsWindow: SettingsWindowHost?

  /// URLs currently inside a startAccessingSecurityScopedResource grant,
  /// keyed by an opaque per-grant token (NOT by path: two overlapping grants
  /// on the same file must each balance their own start with a stop).
  private var activeScopedUrls: [String: URL] = [:]
  private var nextGrantToken = 0

  /// The menu bar, toolbar and Dock menu's commands (MainMenu.swift).
  private(set) var commands: CommandCenter?
  private var seanceToolbar: SeanceToolbar?

  /// The app's one main window, for the app delegate's reopen and Dock
  /// menu. Set once the window has loaded.
  private(set) static weak var shared: MainFlutterWindow?

  override func awakeFromNib() {
    // Séance's windows never tab (the app's, and Settings' with its own
    // `tabbingMode`); disabling automatic window tabbing stops AppKit from
    // injecting a View menu full of tab commands ("Show Tab Bar", etc.).
    NSWindow.allowsAutomaticWindowTabbing = false

    // The integrated titlebar (macos_titlebar.dart): macos_window_utils
    // hosts the Flutter view in its own controller, whose click
    // passthrough lets the header's buttons take clicks inside the
    // titlebar band. The Flutter controller inside it is still the
    // accessibility guard (SeanceFlutterViewController.m).
    let windowUtilsController = MacOSWindowUtilsViewController(
      flutterViewController: SeanceFlutterViewController())
    let flutterViewController = windowUtilsController.flutterViewController
    self.contentViewController = windowUtilsController
    // Default desktop window size, matching the Linux and Windows runners
    // (the window-state service restores the user's own frame after the
    // first launch); 1800x1600 overflowed most laptop screens.
    self.setContentSize(NSSize(width: 1280, height: 800))
    self.center()
    // Starts from a standard titlebar; Dart makes it transparent and adds
    // the unified toolbar before the window is first shown.
    MainFlutterWindowManipulator.start(mainFlutterWindow: self)

    // Channel used by our menu items to trigger Dart actions.
    menuChannel = FlutterMethodChannel(
      name: "seance/menu",
      binaryMessenger: flutterViewController.engine.binaryMessenger)

    // Dart → native: the commands' states, the window's title, and alerts.
    menuChannel?.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(nil)
        return
      }
      switch call.method {
      case "setCommandStates":
        self.commands?.apply(call.arguments as? [String: Any] ?? [:])
        result(nil)
      case "setWindowTitle":
        let arguments = call.arguments as? [String: Any]
        self.title = arguments?["title"] as? String ?? "Séance"
        self.subtitle = arguments?["subtitle"] as? String ?? ""
        result(nil)
      case "showAlert":
        self.showAlert(call.arguments as? [String: Any] ?? [:], result: result)
      case "popUpMenu":
        let items = (call.arguments as? [String: Any])?["items"] as? [[String: Any]] ?? []
        result(ContextMenu(items).popUp())
      case "setDockBadge":
        NSApp.dockTile.badgeLabel = call.arguments as? String
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    if let menuChannel {
      let commands = CommandCenter(channel: menuChannel, mainWindow: self)
      self.commands = commands
      let toolbar = SeanceToolbar(commands: commands)
      toolbar.install(on: self)
      seanceToolbar = toolbar
    }
    MainFlutterWindow.shared = self

    filesChannel = FlutterMethodChannel(
      name: "seance/files",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    filesChannel?.setMethodCallHandler { call, result in
      if call.method == "pickApplication" {
        let panel = NSOpenPanel()
        panel.title = "Choose an editor application"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true
        // .applicationBundle (com.apple.application-bundle) is the exact
        // equivalent of the legacy `allowedFileTypes = ["app"]` filter, which
        // macOS 12 deprecated. Unconditional: allowedContentTypes needs
        // macOS 11, and this project's MACOSX_DEPLOYMENT_TARGET is 12.0
        // (Runner.xcodeproj, every configuration — see AGENTS.md §3), so an
        // availability check here is always true and its dead `else` branch
        // would still be compiled, putting the deprecation warning back.
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.begin { response in
          guard response == .OK, let url = panel.url else {
            result(nil)
            return
          }
          guard let bundle = Bundle(url: url),
                let bundleIdentifier = bundle.bundleIdentifier else {
            result(FlutterError(
              code: "INVALID_APPLICATION",
              message: "The selected item is not an application bundle.",
              details: nil))
            return
          }
          let info = bundle.infoDictionary
          let displayName = (info?["CFBundleDisplayName"] as? String)
            ?? (info?["CFBundleName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent
          result([
            "displayName": displayName,
            "bundleIdentifier": bundleIdentifier,
          ])
        }
        return
      }
      guard call.method == "openWithApplication",
            let arguments = call.arguments as? [String: Any],
            let path = arguments["path"] as? String,
            let bundleIdentifier = arguments["bundleIdentifier"] as? String else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard let application = NSWorkspace.shared.urlForApplication(
        withBundleIdentifier: bundleIdentifier) else {
        result(FlutterError(
          code: "APPLICATION_NOT_FOUND",
          message: "The configured editor application is not installed.",
          details: nil))
        return
      }
      let configuration = NSWorkspace.OpenConfiguration()
      NSWorkspace.shared.open(
        [URL(fileURLWithPath: path)],
        withApplicationAt: application,
        configuration: configuration) { _, error in
          if let error = error {
            DispatchQueue.main.async {
              result(FlutterError(
                code: "OPEN_FAILED",
                message: error.localizedDescription,
                details: nil))
            }
          } else {
            DispatchQueue.main.async { result(nil) }
          }
        }
    }

    // Identity files ("reference, don't store" SSH keys): a native open panel
    // that can show dot-directories like ~/.ssh, plus security-scoped
    // bookmarks so a key picked outside ~/.ssh stays readable at connect time
    // across relaunches (the sandbox forgets plain picker grants on quit).
    bookmarksChannel = FlutterMethodChannel(
      name: "seance/secure_bookmarks",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    bookmarksChannel?.setMethodCallHandler { [weak self] call, result in
      self?.handleBookmarkCall(call, result: result)
    }

    settingsWindow = SettingsWindowHost(
      mainWindow: self,
      messenger: flutterViewController.engine.binaryMessenger)

    // Full screen: AppKit keeps a window's toolbar permanently visible in
    // full screen, in an opaque strip of its own above the content. The
    // empty unified toolbar that gives the windowed titlebar its 52 pt
    // band would cover the header drawn beneath it, so it hides for the
    // duration and the titlebar only slides in with the menu bar.
    // `seance/window` tells the Dart side the band is gone, so it stops
    // reserving it above pushed routes. Notifications rather than delegate
    // methods, because window_manager owns the window's delegate.
    windowChannel = FlutterMethodChannel(
      name: "seance/window",
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

    // Replaces the storyboard's menu bar once AppKit has loaded it.
    DispatchQueue.main.async { [weak self] in
      self?.commands?.installMenuBar()
    }

    super.awakeFromNib()
  }

  /// The Settings window closes with this one. The close button only hides
  /// this window (Dart intercepts it, `WindowStateService`), so this runs
  /// when AppKit closes it for good, at termination.
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
    windowChannel?.invokeMethod("toolbarBandChanged", arguments: !value)
  }

  /// Keep the window invisible while Dart puts it back where it was closed:
  /// WindowStateService.restoreAndTrack() (main.dart, before runApp) applies
  /// the previous session's frame and then shows the window — always, even
  /// when restoring fails — so the storyboard's default-size window never
  /// flashes. Do not remove this without removing that contract too.
  override public func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
    super.order(place, relativeTo: otherWin)
    hiddenWindowAtLaunch()
  }

  /// The user's real home directory. The sandbox's $HOME is the app
  /// container, so the open panel would otherwise start in the wrong place.
  private func realHomeDirectory() -> URL? {
    guard let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir else {
      return nil
    }
    return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
  }

  private func handleBookmarkCall(
    _ call: FlutterMethodCall, result: @escaping FlutterResult
  ) {
    switch call.method {
    case "pickIdentityFile":
      let panel = NSOpenPanel()
      panel.title = "Choose an SSH identity file"
      panel.canChooseFiles = true
      panel.canChooseDirectories = false
      panel.allowsMultipleSelection = false
      panel.resolvesAliases = true
      // Identity files live in dot-directories; without this the panel shows
      // an apparently empty home.
      panel.showsHiddenFiles = true
      if let home = realHomeDirectory() {
        let ssh = home.appendingPathComponent(".ssh", isDirectory: true)
        panel.directoryURL =
          FileManager.default.fileExists(atPath: ssh.path) ? ssh : home
      }
      panel.begin { response in
        guard response == .OK, let url = panel.url else {
          result(nil)
          return
        }
        // Mint the bookmark while the picker's grant is live. Read-only: the
        // app only ever reads identity files, so the standing grant must not
        // be able to modify them. If minting fails the path alone still
        // helps: ~/.ssh works via the entitlement, and the picker grant
        // covers this process for anything else.
        let bookmark = try? url.bookmarkData(
          options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
          includingResourceValuesForKeys: nil,
          relativeTo: nil)
        var payload: [String: Any] = ["path": url.path]
        if let bookmark = bookmark {
          payload["bookmark"] = bookmark.base64EncodedString()
        }
        result(payload)
      }
    case "resolveBookmark":
      guard let arguments = call.arguments as? [String: Any],
            let encoded = arguments["bookmark"] as? String,
            let data = Data(base64Encoded: encoded) else {
        result(FlutterError(
          code: "BAD_BOOKMARK", message: "Malformed bookmark data.",
          details: nil))
        return
      }
      var isStale = false
      guard let url = try? URL(
        resolvingBookmarkData: data,
        options: .withSecurityScope,
        relativeTo: nil,
        bookmarkDataIsStale: &isStale) else {
        result(FlutterError(
          code: "RESOLVE_FAILED",
          message: "The saved file grant could not be resolved.",
          details: nil))
        return
      }
      guard url.startAccessingSecurityScopedResource() else {
        result(FlutterError(
          code: "ACCESS_DENIED",
          message: "The saved file grant was not honored.",
          details: nil))
        return
      }
      nextGrantToken += 1
      let token = String(nextGrantToken)
      activeScopedUrls[token] = url
      var payload: [String: Any] = ["path": url.path, "token": token]
      // A stale bookmark still resolves once; re-mint it now, while access is
      // live, so the caller can persist a fresh grant.
      if isStale,
         let refreshed = try? url.bookmarkData(
           options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
           includingResourceValuesForKeys: nil,
           relativeTo: nil) {
        payload["refreshedBookmark"] = refreshed.base64EncodedString()
      }
      result(payload)
    case "stopAccess":
      if let arguments = call.arguments as? [String: Any],
         let token = arguments["token"] as? String,
         let url = activeScopedUrls.removeValue(forKey: token) {
        url.stopAccessingSecurityScopedResource()
      }
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: responder actions

  /// The toolbar's system sidebar and inspector buttons send these down
  /// the responder chain; the window is the end of it.
  @objc func toggleSidebar(_ sender: Any?) {
    commands?.run("toggleSidebar")
  }

  @objc func toggleInspector(_ sender: Any?) {
    commands?.run("toggleInspector")
  }

  override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
    switch item.action {
    case #selector(toggleSidebar(_:)):
      return commands?.state("toggleSidebar").enabled ?? false
    case #selector(toggleInspector(_:)):
      return commands?.state("toggleInspector").enabled ?? false
    default:
      return super.validateUserInterfaceItem(item)
    }
  }

  // MARK: alerts

  /// A native alert for Dart's confirmations: a sheet on this window while
  /// it is on screen, app-modal otherwise (a quit with the window closed).
  /// Answers `{button: index, suppressed: bool}`; the first button is the
  /// default one, and one titled Cancel takes Escape.
  private func showAlert(_ arguments: [String: Any], result: @escaping FlutterResult) {
    let alert = NSAlert()
    alert.messageText = arguments["message"] as? String ?? ""
    alert.informativeText = arguments["informative"] as? String ?? ""
    alert.alertStyle = arguments["style"] as? String == "critical" ? .critical : .warning
    for title in arguments["buttons"] as? [String] ?? ["OK"] {
      alert.addButton(withTitle: title)
    }
    if let destructive = arguments["destructive"] as? Int,
      alert.buttons.indices.contains(destructive)
    {
      alert.buttons[destructive].hasDestructiveAction = true
    }
    if let suppression = arguments["suppression"] as? String {
      alert.showsSuppressionButton = true
      alert.suppressionButton?.title = suppression
    }
    func answer(_ response: NSApplication.ModalResponse) {
      result([
        "button": response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue,
        "suppressed": alert.suppressionButton?.state == .on,
      ])
    }
    if isVisible && attachedSheet == nil {
      alert.beginSheetModal(for: self, completionHandler: answer)
    } else {
      answer(alert.runModal())
    }
  }
}

/// A context menu Dart describes (`showMacContextMenu`): built as an
/// NSMenu, opened at the pointer, and answered with the chosen row's id
/// once it closes, or nil when dismissed.
private final class ContextMenu: NSObject {
  private let menu = NSMenu()
  private var chosen: String?

  init(_ items: [[String: Any]]) {
    super.init()
    build(items, into: menu)
  }

  func popUp() -> String? {
    // Returns when the menu closes; the choice landed in `choose` first.
    menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    return chosen
  }

  @objc private func choose(_ sender: NSMenuItem) {
    chosen = sender.representedObject as? String
  }

  private func build(_ items: [[String: Any]], into menu: NSMenu) {
    menu.autoenablesItems = false
    for spec in items {
      if spec["separator"] as? Bool == true {
        menu.addItem(.separator())
        continue
      }
      let item = NSMenuItem(title: spec["title"] as? String ?? "", action: nil, keyEquivalent: "")
      if let children = spec["items"] as? [[String: Any]] {
        let submenu = NSMenu(title: item.title)
        build(children, into: submenu)
        item.submenu = submenu
      } else {
        item.action = #selector(choose(_:))
        item.target = self
        item.representedObject = spec["id"] as? String
      }
      item.isEnabled = spec["enabled"] as? Bool ?? true
      if spec["checked"] as? Bool == true { item.state = .on }
      if let key = spec["key"] as? String {
        item.keyEquivalent = key
        var mask: NSEvent.ModifierFlags = []
        for name in spec["modifiers"] as? [String] ?? [] {
          switch name {
          case "command": mask.insert(.command)
          case "shift": mask.insert(.shift)
          case "option": mask.insert(.option)
          case "control": mask.insert(.control)
          default: break
          }
        }
        item.keyEquivalentModifierMask = mask
      }
      menu.addItem(item)
    }
  }
}
