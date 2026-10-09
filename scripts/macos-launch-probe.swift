import ApplicationServices
import Cocoa

// One look at a running app for scripts/test-desktop-launch.py: its
// on-screen windows and, when this process may read them, its menu bar
// titles. CGWindowList answers without permission for bounds; a window's
// title needs Screen Recording and the menu bar needs Accessibility, so
// either may be null.
// Usage: macos-launch-probe <pid>
// Prints: {"windows":[{"height":600,"title":"…"}],"menus":["Apple","File"]}

private func onScreenWindows(_ pid: pid_t) -> [[String: Any]] {
  let windows =
    CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
  return windows.compactMap { window in
    guard (window[kCGWindowOwnerPID as String] as? Int32) == pid,
      (window[kCGWindowLayer as String] as? Int) == 0,
      let bounds = window[kCGWindowBounds as String] as? NSDictionary,
      let frame = CGRect(dictionaryRepresentation: bounds)
    else { return nil }
    let title = window[kCGWindowName as String] as? String
    return ["height": frame.height, "title": title ?? NSNull()]
  }
}

private func menuTitles(_ pid: pid_t) -> [String]? {
  guard AXIsProcessTrusted() else { return nil }
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

guard CommandLine.arguments.count == 2, let pid = pid_t(CommandLine.arguments[1]) else {
  FileHandle.standardError.write("usage: macos-launch-probe <pid>\n".data(using: .utf8)!)
  exit(2)
}

let report: [String: Any] = [
  "windows": onScreenWindows(pid),
  "menus": menuTitles(pid) ?? NSNull(),
]
let json = try! JSONSerialization.data(withJSONObject: report)
FileHandle.standardOutput.write(json)
