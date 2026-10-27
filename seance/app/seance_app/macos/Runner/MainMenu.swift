import Cocoa
import FlutterMacOS

/// The menu bar, the main window's toolbar and the Dock menu, over the
/// commands Dart publishes (`lib/services/mac_commands.dart`).
///
/// AppKit owns the structure, the key equivalents and everything the
/// system provides (Services, the window list, Help search, full screen);
/// Dart owns what each Séance command means and whether it applies right
/// now. Dart pushes every command's state on `seance/menu` whenever it
/// changes (`setCommandStates`), so validation here is synchronous, and a
/// chosen item crosses back as `run` with the command's name.
///
///     Dart ──setCommandStates──▶ CommandCenter ──validate──▶ NSMenuItem
///     NSMenuItem / NSToolbarItem ──run(name)──▶ Dart
///
/// A disabled item never takes its key equivalent, so a key the app has no
/// use for right now still reaches the focused Flutter control.
final class CommandCenter: NSObject, NSMenuItemValidation, NSToolbarItemValidation {
  /// One command as Dart last described it.
  struct State {
    var enabled = false
    var checked: Bool?
    var title: String?
  }

  private let channel: FlutterMethodChannel
  private weak var mainWindow: NSWindow?
  private var states: [String: State] = [:]

  /// The servers the Dock menu offers, in list order: (id, label).
  private var dockServers: [(String, String)] = []

  /// Edit commands that go to Dart while the main window is key and to the
  /// key window's own responders otherwise (the Settings window's fields).
  private static let editSelectors: [String: Selector] = [
    "undo": Selector(("undo:")),
    "redo": Selector(("redo:")),
    "cut": #selector(NSText.cut(_:)),
    "copy": #selector(NSText.copy(_:)),
    "paste": #selector(NSText.paste(_:)),
    "selectAll": #selector(NSText.selectAll(_:)),
  ]

  init(channel: FlutterMethodChannel, mainWindow: NSWindow) {
    self.channel = channel
    self.mainWindow = mainWindow
    super.init()
  }

  // MARK: Dart → native

  /// `{name: {enabled, checked?, title?}}` for the commands that changed,
  /// plus `dockServers: [[id, label]]` when the list changed.
  func apply(_ payload: [String: Any]) {
    for (name, value) in payload {
      if name == "dockServers" {
        dockServers = (value as? [[String]] ?? []).compactMap {
          $0.count == 2 ? ($0[0], $0[1]) : nil
        }
        continue
      }
      guard let fields = value as? [String: Any] else { continue }
      states[name] = State(
        enabled: fields["enabled"] as? Bool ?? false,
        checked: fields["checked"] as? Bool,
        title: fields["title"] as? String)
    }
    // Retitle and re-check now, not on the next menu tracking: the menu bar
    // may be open, and the toolbar shows its state all the time.
    NSApp.mainMenu?.update()
    mainWindow?.toolbar?.validateVisibleItems()
    toolbarStateChanged?()
  }

  /// The toolbar's own refresh for items whose look follows a state
  /// (the connection item's symbol), set by `SeanceToolbar`.
  var toolbarStateChanged: (() -> Void)?

  func state(_ name: String) -> State { states[name] ?? State() }

  // MARK: native → Dart

  @objc func runItem(_ sender: Any?) {
    let name: String?
    switch sender {
    case let item as NSMenuItem: name = item.representedObject as? String
    case let item as NSToolbarItem: name = item.itemIdentifier.rawValue
    default: name = nil
    }
    guard let name else { return }
    run(name)
  }

  func run(_ name: String) {
    channel.invokeMethod("run", arguments: name)
  }

  /// Edit menu: Dart while the main window is key, which knows whether the
  /// terminal or a text field holds focus; the standard action down the key
  /// window's responder chain otherwise.
  @objc func edit(_ sender: NSMenuItem) {
    guard let name = sender.representedObject as? String else { return }
    if routesEditToDart {
      run(name)
      return
    }
    if let selector = Self.editSelectors[name] {
      NSApp.sendAction(selector, to: nil, from: sender)
    }
  }

  /// ⌘W: the active tab in the main window, the key window itself anywhere
  /// else (Settings, About), as Close does on every Mac.
  @objc func closeTabOrWindow(_ sender: Any?) {
    guard let key = NSApp.keyWindow else { return }
    if key === mainWindow && state("closeTab").enabled {
      run("closeTab")
      return
    }
    key.performClose(sender)
  }

  @objc func closeWindow(_ sender: Any?) {
    NSApp.keyWindow?.performClose(sender)
  }

  @objc func openServerFromDock(_ sender: NSMenuItem) {
    guard let id = sender.representedObject as? String else { return }
    channel.invokeMethod("openServer", arguments: id)
  }

  private var routesEditToDart: Bool {
    guard let main = mainWindow else { return false }
    return NSApp.keyWindow === main
  }

  // MARK: validation

  func validateMenuItem(_ item: NSMenuItem) -> Bool {
    switch item.action {
    case #selector(edit(_:)):
      guard let name = item.representedObject as? String else { return false }
      if routesEditToDart {
        let state = state(name)
        if let title = state.title { item.title = title }
        return state.enabled
      }
      item.title = Self.editTitles[name] ?? item.title
      return standardResponderValidates(name, item: item)
    case #selector(closeTabOrWindow(_:)):
      guard let key = NSApp.keyWindow else { return false }
      if key === mainWindow {
        let tab = state("closeTab")
        if tab.enabled {
          item.title = tab.title ?? "Close Tab"
          return true
        }
        item.title = "Close Window"
        return state("closeWindow").enabled
      }
      item.title = "Close"
      return key.styleMask.contains(.closable)
    case #selector(closeWindow(_:)):
      guard let key = NSApp.keyWindow else { return false }
      // Only distinct from ⌘W while the main window has a tab to close;
      // otherwise the two would read the same.
      item.isHidden = !(key === mainWindow && state("closeTab").enabled)
      if key === mainWindow { return state("closeWindow").enabled }
      return key.styleMask.contains(.closable)
    case #selector(openServerFromDock(_:)):
      return true
    case #selector(runItem(_:)):
      guard let name = item.representedObject as? String else { return false }
      if sheetUp && !Self.availableUnderSheet.contains(name) { return false }
      if name == "showMainWindow" {
        // The window list names the window while it is open; this item
        // brings it back once it is closed.
        item.isHidden = mainWindow?.isVisible ?? false
      }
      let state = state(name)
      if let title = state.title { item.title = title }
      if let checked = state.checked { item.state = checked ? .on : .off }
      return state.enabled
    default:
      return true
    }
  }

  func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
    !sheetUp && state(item.itemIdentifier.rawValue).enabled
  }

  /// A native alert is up on the main window (Dart's dialogs count as
  /// modal on their own side): its commands wait, as under any sheet.
  private var sheetUp: Bool { mainWindow?.attachedSheet != nil }

  /// What stays available while a sheet is up: the app's own windows and
  /// help, not the window's content.
  private static let availableUnderSheet: Set<String> = [
    "settings", "help", "checkForUpdates",
  ]

  private static let editTitles = [
    "undo": "Undo", "redo": "Redo", "cut": "Cut", "copy": "Copy",
    "paste": "Paste", "selectAll": "Select All",
  ]

  /// Whether the key window's responder chain takes [name]'s standard
  /// selector and, if it validates items, accepts it now. Asked with a
  /// stand-in item carrying that selector, because responders such as
  /// NSTextView validate by the item's action.
  private func standardResponderValidates(_ name: String, item: NSMenuItem) -> Bool {
    guard let selector = Self.editSelectors[name],
      let target = NSApp.target(forAction: selector, to: nil, from: item)
    else { return false }
    let probe = NSMenuItem(title: item.title, action: selector, keyEquivalent: "")
    if let validating = target as? NSMenuItemValidation {
      return validating.validateMenuItem(probe)
    }
    return true
  }

  // MARK: building

  /// Replaces the storyboard's menu bar. Called once the main window and
  /// its channel exist.
  func installMenuBar() {
    let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Séance"
    let bar = NSMenu(title: "Main Menu")

    let appMenu = menu(appName) {
      $0.addItem(withTitle: "About \(appName)",
        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
      $0.addItem(.separator())
      $0.addItem(command("checkForUpdates", "Check for Updates…"))
      $0.addItem(.separator())
      $0.addItem(command("settings", "Settings…", key: ","))
      $0.addItem(.separator())
      let services = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
      services.submenu = NSMenu(title: "Services")
      NSApp.servicesMenu = services.submenu
      $0.addItem(services)
      $0.addItem(.separator())
      $0.addItem(withTitle: "Hide \(appName)",
        action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
      let others = $0.addItem(withTitle: "Hide Others",
        action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
      others.keyEquivalentModifierMask = [.command, .option]
      $0.addItem(withTitle: "Show All",
        action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
      $0.addItem(.separator())
      $0.addItem(withTitle: "Quit \(appName)",
        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }
    add(appMenu, to: bar)

    add(menu("File") {
      $0.addItem(command("newServer", "New Server…", key: "n"))
      $0.addItem(command("newTab", "New Tab", key: "t"))
      $0.addItem(command("newLocalShell", "New Local Shell", key: "n", modifiers: [.command, .shift]))
      $0.addItem(.separator())
      let close = NSMenuItem(title: "Close Tab", action: #selector(closeTabOrWindow(_:)), keyEquivalent: "w")
      close.target = self
      $0.addItem(close)
      let closeWindow = NSMenuItem(title: "Close Window", action: #selector(closeWindow(_:)), keyEquivalent: "w")
      closeWindow.keyEquivalentModifierMask = [.command, .shift]
      closeWindow.allowsKeyEquivalentWhenHidden = true
      closeWindow.target = self
      $0.addItem(closeWindow)
      $0.addItem(.separator())
      $0.addItem(command("save", "Save", key: "s"))
      $0.addItem(command("saveLocally", "Save Without Uploading", key: "s", modifiers: [.command, .shift]))
      $0.addItem(command("exportText", "Export Text As…"))
      $0.addItem(.separator())
      $0.addItem(command("importSshConfig", "Import SSH Config…"))
    }, to: bar)

    add(menu("Edit") {
      $0.addItem(editCommand("undo", "Undo", key: "z"))
      $0.addItem(editCommand("redo", "Redo", key: "z", modifiers: [.command, .shift]))
      $0.addItem(.separator())
      $0.addItem(editCommand("cut", "Cut", key: "x"))
      $0.addItem(editCommand("copy", "Copy", key: "c"))
      $0.addItem(editCommand("paste", "Paste", key: "v"))
      $0.addItem(editCommand("selectAll", "Select All", key: "a"))
      $0.addItem(.separator())
      $0.addItem(command("clearScrollback", "Clear Scrollback", key: "k", modifiers: [.command, .option]))
      $0.addItem(.separator())
      let find = NSMenuItem(title: "Find", action: nil, keyEquivalent: "")
      find.submenu = menu("Find") {
        $0.addItem(command("find", "Find…", key: "f"))
        $0.addItem(command("findNext", "Find Next", key: "g"))
        $0.addItem(command("findPrevious", "Find Previous", key: "g", modifiers: [.command, .shift]))
        $0.addItem(command("useSelectionForFind", "Use Selection for Find", key: "e"))
      }
      $0.addItem(find)
    }, to: bar)

    add(menu("View") {
      // No Hide Toolbar: the window's header is drawn to sit under it.
      $0.addItem(withTitle: "Customize Toolbar…",
        action: #selector(NSWindow.runToolbarCustomizationPalette(_:)), keyEquivalent: "")
      $0.addItem(.separator())
      $0.addItem(command("toggleSidebar", "Hide Sidebar", key: "s", modifiers: [.command, .control]))
      $0.addItem(command("toggleInspector", "Hide Inspector", key: "i", modifiers: [.command, .option]))
      $0.addItem(command("showFiles", "Files", key: "1", modifiers: [.command, .option]))
      $0.addItem(command("showGit", "Git", key: "2", modifiers: [.command, .option]))
      $0.addItem(command("showSnippets", "Snippets", key: "3", modifiers: [.command, .option]))
      $0.addItem(command("showAssistant", "Assistant", key: "4", modifiers: [.command, .option]))
      $0.addItem(.separator())
      $0.addItem(command("toggleDensity", "Use Compact Sidebar Rows"))
      $0.addItem(.separator())
      $0.addItem(command("actualSize", "Actual Size", key: "0"))
      $0.addItem(command("zoomIn", "Zoom In", key: "+"))
      // ⌘= is what the key under "+" types without Shift on most layouts.
      let zoomInAlias = command("zoomIn", "Zoom In", key: "=")
      zoomInAlias.isHidden = true
      zoomInAlias.allowsKeyEquivalentWhenHidden = true
      $0.addItem(zoomInAlias)
      $0.addItem(command("zoomOut", "Zoom Out", key: "-"))
      $0.addItem(.separator())
      let fullScreen = $0.addItem(withTitle: "Enter Full Screen",
        action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
      fullScreen.keyEquivalentModifierMask = [.command, .control]
    }, to: bar)

    add(menu("Server") {
      $0.addItem(command("connectToServer", "Connect to Server…", key: "o"))
      // ⌥⌘F, the server filter's chord before the menu bar had this item.
      let filterAlias = command("connectToServer", "Connect to Server…", key: "f", modifiers: [.command, .option])
      filterAlias.isHidden = true
      filterAlias.allowsKeyEquivalentWhenHidden = true
      $0.addItem(filterAlias)
      $0.addItem(.separator())
      $0.addItem(command("reconnect", "Reconnect", key: "r"))
      $0.addItem(command("disconnect", "Disconnect"))
      $0.addItem(.separator())
      $0.addItem(command("editServer", "Edit Server…", key: "i"))
      $0.addItem(command("duplicateServer", "Duplicate Server", key: "d"))
      $0.addItem(command("togglePin", "Pin to Top"))
      $0.addItem(command("copySshCommand", "Copy SSH Command", key: "c", modifiers: [.command, .option]))
      $0.addItem(.separator())
      $0.addItem(command("deleteServer", "Delete Server…", key: "\u{8}"))
      $0.addItem(.separator())
      $0.addItem(command("generateCommand", "Generate Command…", key: "k"))
    }, to: bar)

    let windowMenu = menu("Window") {
      $0.addItem(withTitle: "Minimize",
        action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
      $0.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
      $0.addItem(.separator())
      $0.addItem(command("previousTab", "Show Previous Tab", key: "[", modifiers: [.command, .shift]))
      $0.addItem(command("nextTab", "Show Next Tab", key: "]", modifiers: [.command, .shift]))
      $0.addItem(.separator())
      $0.addItem(withTitle: "Bring All to Front",
        action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
      $0.addItem(command("showMainWindow", appName))
    }
    add(windowMenu, to: bar)
    NSApp.windowsMenu = windowMenu

    let helpMenu = menu("Help") {
      $0.addItem(command("help", "\(appName) Help"))
      $0.addItem(command("keyboardShortcuts", "Keyboard Shortcuts", key: "/"))
    }
    add(helpMenu, to: bar)
    NSApp.helpMenu = helpMenu

    NSApp.mainMenu = bar
  }

  /// The Dock icon's menu: the servers to connect to, then a local shell.
  func dockMenu() -> NSMenu {
    let menu = NSMenu()
    for (id, label) in dockServers {
      let item = NSMenuItem(title: label, action: #selector(openServerFromDock(_:)), keyEquivalent: "")
      item.target = self
      item.representedObject = id
      menu.addItem(item)
    }
    if !dockServers.isEmpty { menu.addItem(.separator()) }
    menu.addItem(command("newLocalShell", "New Local Shell"))
    menu.addItem(command("newServer", "New Server…"))
    return menu
  }

  private func menu(_ title: String, _ build: (NSMenu) -> Void) -> NSMenu {
    let menu = NSMenu(title: title)
    build(menu)
    return menu
  }

  private func add(_ submenu: NSMenu, to bar: NSMenu) {
    let item = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
    item.submenu = submenu
    bar.addItem(item)
  }

  private func command(
    _ name: String, _ title: String, key: String = "",
    modifiers: NSEvent.ModifierFlags = [.command]
  ) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: #selector(runItem(_:)), keyEquivalent: key)
    item.keyEquivalentModifierMask = key.isEmpty ? [] : modifiers
    item.target = self
    item.representedObject = name
    return item
  }

  private func editCommand(
    _ name: String, _ title: String, key: String,
    modifiers: NSEvent.ModifierFlags = [.command]
  ) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: #selector(edit(_:)), keyEquivalent: key)
    item.keyEquivalentModifierMask = modifiers
    item.target = self
    item.representedObject = name
    return item
  }
}
