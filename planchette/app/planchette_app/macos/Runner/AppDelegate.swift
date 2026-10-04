import Cocoa
import FlutterMacOS

#if !PLANCHETTE_DOCUMENT_OPEN_TEST
@main
#endif
class AppDelegate: FlutterAppDelegate {
  private var documentChannel: FlutterMethodChannel?
  private var pendingPaths: [String] = []
  private var documentReceiverReady = false

  func installDocumentChannel(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "planchette/documents", binaryMessenger: messenger)
    documentChannel = channel
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self, call.method == "ready" else {
        result(FlutterMethodNotImplemented)
        return
      }
      self.documentReceiverReady = true
      let paths = self.pendingPaths
      self.pendingPaths.removeAll()
      result(paths)
    }
  }

  // AppKit prefers this inherited Flutter callback over openFiles. File URLs
  // must reach our document queue; other URL schemes still belong to plugins.
  // This delegate owns document delivery, so plugins do not receive file URLs.
  override func application(_ sender: NSApplication, open urls: [URL]) {
    let files = urls.filter { $0.isFileURL }.map { $0.path }
    if !files.isEmpty {
      receiveDocuments(sender, paths: files)
    }
    let otherURLs = urls.filter { !$0.isFileURL }
    if !otherURLs.isEmpty {
      super.application(sender, open: otherURLs)
    }
  }

  override func application(_ sender: NSApplication, openFiles filenames: [String]) {
    receiveDocuments(sender, paths: filenames)
    sender.reply(toOpenOrPrint: .success)
  }

  // Finder can deliver paths before Dart registers its handler. Keep both
  // native entrypoints on the same startup queue and ready handshake.
  private func receiveDocuments(_ sender: NSApplication, paths: [String]) {
    if documentReceiverReady {
      documentChannel?.invokeMethod("open", arguments: paths)
    } else {
      pendingPaths.append(contentsOf: paths)
    }
    // No raise here: Dart routes the paths to the window that owns the
    // file (or the last-active one, or a fresh window) and raises that
    // window through planchette/windows — its raise also brings the app
    // itself forward when the event arrived in the background. Raising
    // mainFlutterWindow would re-show the hidden main view and steal the
    // owning window's focus.
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
