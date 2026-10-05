import ApplicationServices
import Cocoa

// Waits for a launched Planchette to come up as Dart puts it up: the main
// window on screen (it launches hidden until Dart places and shows it) and
// the app's own File menu in place of the storyboard's stock menus. A Dart
// startup failure shows neither while the process keeps running.
// Usage: launch-probe <pid> <timeout seconds>

/// The workspace's minimum content height (lib/services/desktop_window.dart).
/// The app's other layer-0 windows, its menu bar strips, are much shorter.
private let minimumWindowHeight: CGFloat = 400
private let appMenuTitle = "File"
private let pollInterval: useconds_t = 200_000
/// How long the app must stay up once it is: a launch that dies a few
/// seconds in is as broken as one that never shows.
private let stableSeconds: TimeInterval = 5

private func hasOnScreenWindow(_ pid: pid_t) -> Bool {
  let windows =
    CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
  return windows.contains { window in
    guard (window[kCGWindowOwnerPID as String] as? Int32) == pid,
      (window[kCGWindowLayer as String] as? Int) == 0,
      let bounds = window[kCGWindowBounds as String] as? NSDictionary,
      let frame = CGRect(dictionaryRepresentation: bounds)
    else { return false }
    return frame.height >= minimumWindowHeight
  }
}

private func menuTitles(_ pid: pid_t) -> [String] {
  let app = AXUIElementCreateApplication(pid)
  var menuBar: CFTypeRef?
  guard AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &menuBar) == .success
  else { return [] }
  var children: CFTypeRef?
  // The AX API hands back an untyped reference; a menu bar is an element.
  guard AXUIElementCopyAttributeValue(
    menuBar as! AXUIElement, kAXChildrenAttribute as CFString, &children) == .success,
    let items = children as? [AXUIElement]
  else { return [] }
  return items.map { item in
    var title: CFTypeRef?
    AXUIElementCopyAttributeValue(item, kAXTitleAttribute as CFString, &title)
    return (title as? String) ?? ""
  }
}

guard CommandLine.arguments.count == 3,
  let pid = pid_t(CommandLine.arguments[1]),
  let timeout = Double(CommandLine.arguments[2])
else {
  FileHandle.standardError.write("usage: launch-probe <pid> <timeout seconds>\n".data(using: .utf8)!)
  exit(2)
}

// Without accessibility trust the menu bar cannot be read; say so rather
// than counting the unchecked menu as passed.
let checksMenus = AXIsProcessTrusted()
if !checksMenus {
  print("Menu check skipped: this process is not trusted for accessibility.")
}

let deadline = Date().addingTimeInterval(timeout)
var windowShown = false
var menus: [String] = []
while Date() < deadline {
  if kill(pid, 0) != 0 {
    print("Planchette (pid \(pid)) exited during launch.")
    exit(1)
  }
  windowShown = hasOnScreenWindow(pid)
  if checksMenus {
    menus = menuTitles(pid)
  }
  if windowShown && (!checksMenus || menus.contains(appMenuTitle)) {
    print("Planchette is up: main window on screen"
      + (checksMenus ? ", menus \(menus.joined(separator: ", "))." : "."))
    let stableUntil = Date().addingTimeInterval(stableSeconds)
    while Date() < stableUntil {
      if kill(pid, 0) != 0 {
        print("Planchette (pid \(pid)) exited after coming up.")
        exit(1)
      }
      usleep(pollInterval)
    }
    exit(0)
  }
  usleep(pollInterval)
}

print("Planchette did not come up within \(Int(timeout)) s: main window "
  + (windowShown ? "on screen" : "never on screen")
  + (checksMenus ? ", menus \(menus.joined(separator: ", "))." : "."))
exit(1)
