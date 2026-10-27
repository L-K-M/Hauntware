import Cocoa

/// The main window's toolbar: the sidebar toggle beside the traffic
/// lights, the session's actions at the trailing end and the inspector
/// toggle last, over the inspector's column. Each item runs the
/// `CommandCenter` command of the same name, so it is enabled, titled and
/// run exactly as its menu item is. Users can rearrange it (View ▸
/// Customize Toolbar…); AppKit saves their arrangement.
///
/// On macOS 26 these are Liquid Glass buttons with no work here: the items
/// are standard bordered toolbar items with SF Symbols.
final class SeanceToolbar: NSObject, NSToolbarDelegate {
  private static let toolbarIdentifier = NSToolbar.Identifier("SeanceMainToolbar")

  /// Shown while the active session is connected: the item disconnects.
  private static let disconnectSymbol = "bolt.horizontal.circle"

  /// Shown otherwise: the item reconnects.
  private static let reconnectSymbol = "arrow.clockwise"

  private struct Spec {
    let label: String
    let symbol: String
    let toolTip: String
  }

  private static let newTab = NSToolbarItem.Identifier("newTab")
  private static let connection = NSToolbarItem.Identifier("connection")
  private static let generateCommand = NSToolbarItem.Identifier("generateCommand")
  private static let find = NSToolbarItem.Identifier("find")
  private static let newServer = NSToolbarItem.Identifier("newServer")
  private static let newLocalShell = NSToolbarItem.Identifier("newLocalShell")
  private static let settings = NSToolbarItem.Identifier("settings")
  private static let inspector = NSToolbarItem.Identifier("toggleInspector")

  private static let specs: [NSToolbarItem.Identifier: Spec] = [
    newTab: Spec(label: "New Tab", symbol: "plus", toolTip: "Open another session on this server"),
    connection: Spec(label: "Reconnect", symbol: reconnectSymbol, toolTip: "Reconnect this session"),
    generateCommand: Spec(label: "Generate Command", symbol: "wand.and.stars",
      toolTip: "Describe a task and get a command for it"),
    find: Spec(label: "Find", symbol: "magnifyingglass", toolTip: "Find in the terminal's scrollback"),
    newServer: Spec(label: "New Server", symbol: "rectangle.stack.badge.plus", toolTip: "Add a server"),
    newLocalShell: Spec(label: "Local Shell", symbol: "apple.terminal", toolTip: "Open a shell on this Mac"),
    settings: Spec(label: "Settings", symbol: "gearshape", toolTip: "Open Settings"),
    inspector: Spec(label: "Inspector", symbol: "sidebar.right", toolTip: "Show or hide the inspector"),
  ]

  private let commands: CommandCenter
  private var items: [NSToolbarItem.Identifier: NSToolbarItem] = [:]

  init(commands: CommandCenter) {
    self.commands = commands
    super.init()
    commands.toolbarStateChanged = { [weak self] in self?.refresh() }
  }

  func install(on window: NSWindow) {
    let toolbar = NSToolbar(identifier: Self.toolbarIdentifier)
    toolbar.delegate = self
    toolbar.displayMode = .iconOnly
    toolbar.allowsUserCustomization = true
    toolbar.autosavesConfiguration = true
    window.toolbar = toolbar
    window.toolbarStyle = .unified
  }

  /// The items whose look follows their command's state.
  private func refresh() {
    guard let item = items[Self.connection] else { return }
    let state = commands.state(Self.connection.rawValue)
    let connected = state.checked ?? false
    let label = state.title ?? (connected ? "Disconnect" : "Reconnect")
    item.label = label
    item.toolTip = label
    item.image = NSImage(
      systemSymbolName: connected ? Self.disconnectSymbol : Self.reconnectSymbol,
      accessibilityDescription: label)
  }

  // MARK: NSToolbarDelegate

  func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    [.toggleSidebar, .flexibleSpace, Self.newTab, Self.connection, Self.generateCommand, .space, Self.inspector]
  }

  func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    [.toggleSidebar, Self.newTab, Self.connection, Self.generateCommand, Self.find,
     Self.newServer, Self.newLocalShell, Self.settings, Self.inspector, .space, .flexibleSpace]
  }

  func toolbar(
    _ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
    willBeInsertedIntoToolbar flag: Bool
  ) -> NSToolbarItem? {
    guard let spec = Self.specs[identifier] else { return nil }
    let item = NSToolbarItem(itemIdentifier: identifier)
    item.label = spec.label
    item.paletteLabel = spec.label
    item.toolTip = spec.toolTip
    item.image = NSImage(systemSymbolName: spec.symbol, accessibilityDescription: spec.label)
    item.isBordered = true
    item.target = commands
    item.action = #selector(CommandCenter.run(_:))
    if flag { items[identifier] = item }
    if identifier == Self.connection { DispatchQueue.main.async { [weak self] in self?.refresh() } }
    return item
  }

  func toolbarDidRemoveItem(_ notification: Notification) {
    guard let item = notification.userInfo?["item"] as? NSToolbarItem else { return }
    if items[item.itemIdentifier] === item { items[item.itemIdentifier] = nil }
  }
}
