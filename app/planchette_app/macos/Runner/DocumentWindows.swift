import Cocoa
import FlutterMacOS

/// The document windows' host: serves `planchette/windows` on the app's
/// engine (the protocol is the library doc of
/// lib/services/window_host.dart).
///
/// Every extra window holds a FlutterViewController made for the app's own
/// engine, so it renders in the same isolate as the main window and shares
/// its state; the engine takes it as a new view once
/// `PlanchetteEnableMultiView` has let it (PlanchetteMultiView.m says why
/// that is not the engine's own method). Closing one only reports
/// `closeRequested`; Dart drops the window's widgets and then asks for
/// `destroy`, and releasing the controller removes its view from the engine.
///
/// The file pickers the app asks for open as sheets on the window that
/// asked, so a dialog never appears on the main window while another
/// window made the request — and never on a hidden main window at all.
final class DocumentWindowsHost: NSObject, NSWindowDelegate {
  private static let channelName = "planchette/windows"

  /// The workspace's minimum content size (WindowOptions in
  /// lib/services/desktop_window.dart), which window_manager applies to
  /// the main window.
  private static let minimumContentSize = NSSize(width: 640, height: 400)
  private static let defaultContentSize = NSSize(width: 1080, height: 760)

  /// How far a new window sits from the one it opens over.
  private static let cascadeOffset: CGFloat = 24

  /// The engine's implicit view: the main window.
  private static let mainViewId: Int64 = 0

  private weak var mainWindow: NSWindow?
  private let engine: FlutterEngine
  private let channel: FlutterMethodChannel
  private let available: Bool

  /// The extra windows by view id. Each owns its controller as its
  /// content view controller.
  private var windows: [Int64: DocumentWindow] = [:]

  init(mainWindow: NSWindow, engine: FlutterEngine) {
    self.mainWindow = mainWindow
    self.engine = engine
    channel = FlutterMethodChannel(
      name: Self.channelName, binaryMessenger: engine.binaryMessenger)
    available = PlanchetteEnableMultiView(engine)
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(FlutterMethodNotImplemented)
        return
      }
      self.handle(call, result: result)
    }
    // Every key window change, the main window's included: its delegate is
    // window_manager's, so a notification rather than a delegate method.
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(keyWindowChanged(_:)),
      name: NSWindow.didBecomeKeyNotification,
      object: nil)
  }

  /// Closes every extra window for good. The main window calls this as it
  /// closes, so the app still quits with its last window.
  func closeAll() {
    for window in Array(windows.values) {
      window.close()
    }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "isAvailable":
      result(available)
    case "create":
      create(
        title: (call.arguments as? [String: Any])?["title"] as? String,
        result: result)
    case "destroy", "activate", "hide", "isFullScreen", "setFullScreen",
      "setTitle", "pickOpenFiles", "pickSavePath":
      let arguments = call.arguments as? [String: Any]
      guard let viewId = (arguments?["viewId"] as? NSNumber)?.int64Value,
        let window = window(for: viewId)
      else {
        result(FlutterError(
          code: "BAD_ARGS", message: "no window has that view id", details: nil))
        return
      }
      switch call.method {
      case "destroy":
        // The main window's view cannot leave the engine; window_manager
        // closes that window, as the app quits. A programmatic close does
        // not ask windowShouldClose.
        if window !== mainWindow {
          window.close()
        } else {
          NSLog("Planchette: destroy on the main window is a no-op; "
            + "window_manager owns closing it")
        }
      case "activate":
        // Shows it again if it was hidden, and makes it key either way.
        // makeKeyAndOrderFront orders a window of an inactive app forward
        // only within the app, so a raise answering a backgrounded
        // file-open or a Dock Quit's review brings the app forward too.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
      case "hide":
        window.orderOut(nil)
      case "isFullScreen":
        result(window.styleMask.contains(.fullScreen))
        return
      case "setTitle":
        guard let title = arguments?["title"] as? String else {
          result(FlutterError(
            code: "BAD_ARGS", message: "setTitle needs a title", details: nil))
          return
        }
        window.title = title
      case "pickOpenFiles":
        pickOpenFiles(on: window, result: result)
        return
      case "pickSavePath":
        pickSavePath(on: window, arguments: arguments, result: result)
        return
      default:
        guard let fullScreen = arguments?["fullScreen"] as? Bool else {
          result(FlutterError(
            code: "BAD_ARGS", message: "setFullScreen needs a fullScreen bool",
            details: nil))
          return
        }
        if window.styleMask.contains(.fullScreen) != fullScreen {
          window.toggleFullScreen(nil)
        }
      }
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func create(title: String?, result: FlutterResult) {
    guard available else {
      result(FlutterError(
        code: "CREATE_FAILED", message: "this engine takes no more views",
        details: nil))
      return
    }
    // The same subclass as the main window's, for the same reason: closing
    // a window tears its controller down, which is what the accessibility
    // guard exists for.
    let controller = PlanchetteFlutterViewController(
      engine: engine, nibName: nil, bundle: nil)
    let viewId = controller.viewIdentifier
    guard viewId != Self.mainViewId else {
      result(FlutterError(
        code: "CREATE_FAILED",
        message: "the engine did not assign a fresh view id", details: nil))
      return
    }

    // The size and place of the window it opens over.
    let reference = documentWindow(NSApp.keyWindow) ?? mainWindow
    let contentSize =
      reference.map { $0.contentRect(forFrameRect: $0.frame).size }
      ?? Self.defaultContentSize

    let window = DocumentWindow(
      contentRect: NSRect(origin: .zero, size: contentSize),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false)
    window.title = title ?? "Planchette"
    // Document tabs belong to the shell; AppKit must not offer a second
    // tab bar (as MainFlutterWindow sets on this one).
    window.tabbingMode = .disallowed
    window.viewId = viewId
    window.contentViewController = controller
    window.setContentSize(contentSize)
    window.contentMinSize = Self.minimumContentSize
    // Owned by `windows`; released on close, which removes its view.
    window.isReleasedWhenClosed = false
    window.delegate = self
    if let reference {
      window.setFrameTopLeftPoint(NSPoint(
        x: reference.frame.minX + Self.cascadeOffset,
        y: reference.frame.maxY - Self.cascadeOffset))
    } else {
      window.center()
    }
    windows[viewId] = window
    window.makeKeyAndOrderFront(nil)
    result(NSNumber(value: viewId))
  }

  /// file_selector's dialogs are app-modal and parent to nothing, which on
  /// a hidden main window looks like a hang; these open as sheets on the
  /// window that asked. Cancel is an empty list or a null, matching the
  /// Dart contract.
  private func pickOpenFiles(on window: NSWindow, result: @escaping FlutterResult) {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = true
    panel.resolvesAliases = true
    panel.beginSheetModal(for: window) { response in
      guard response == .OK else {
        result([])
        return
      }
      result(panel.urls.map { $0.path })
    }
  }

  private func pickSavePath(
    on window: NSWindow,
    arguments: [String: Any]?,
    result: @escaping FlutterResult
  ) {
    guard let suggestedName = arguments?["suggestedName"] as? String,
      !suggestedName.isEmpty
    else {
      result(FlutterError(
        code: "BAD_ARGS", message: "pickSavePath needs a suggestedName",
        details: nil))
      return
    }
    let panel = NSSavePanel()
    panel.nameFieldStringValue = suggestedName
    if let directory = arguments?["initialDirectory"] as? String,
      !directory.isEmpty
    {
      panel.directoryURL = URL(fileURLWithPath: directory)
    }
    panel.beginSheetModal(for: window) { response in
      guard response == .OK else {
        result(nil)
        return
      }
      result(panel.url?.path)
    }
  }

  private func window(for viewId: Int64) -> NSWindow? {
    viewId == Self.mainViewId ? mainWindow : windows[viewId] as NSWindow?
  }

  private func viewId(of window: NSWindow) -> Int64? {
    if window === mainWindow {
      return Self.mainViewId
    }
    return (window as? DocumentWindow)?.viewId
  }

  /// [window] when it is one of the document windows (not a panel).
  private func documentWindow(_ window: NSWindow?) -> NSWindow? {
    guard let window, viewId(of: window) != nil else { return nil }
    return window
  }

  @objc private func keyWindowChanged(_ notification: Notification) {
    guard let window = notification.object as? NSWindow,
      let viewId = viewId(of: window)
    else { return }
    channel.invokeMethod("activated", arguments: ["viewId": NSNumber(value: viewId)])
  }

  /// The close button, ⌘W from the system menu, File ▸ Close: Dart decides,
  /// and destroys the window once its widgets are gone (or quits, for the
  /// last window). A programmatic `close()` does not ask.
  func windowShouldClose(_ sender: NSWindow) -> Bool {
    guard let viewId = viewId(of: sender), sender !== mainWindow else {
      return true
    }
    channel.invokeMethod(
      "closeRequested", arguments: ["viewId": NSNumber(value: viewId)])
    return false
  }

  func windowWillClose(_ notification: Notification) {
    guard let closing = notification.object as? NSWindow,
      closing !== mainWindow,
      let viewId = viewId(of: closing)
    else { return }
    windows[viewId] = nil
    closing.delegate = nil
    // Released after AppKit has finished closing it rather than from inside
    // its own close: that drops the last reference to the controller, whose
    // dealloc invalidates its text fields and removes its view from the
    // engine.
    DispatchQueue.main.async {
      closing.contentViewController = nil
    }
  }
}

/// An extra document window's only distinction is its view id, which the
/// host reports with its events.
final class DocumentWindow: NSWindow {
  var viewId: Int64 = 0
}
