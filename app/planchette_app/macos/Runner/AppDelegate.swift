import Cocoa
import FlutterMacOS

@main
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

  // Finder may deliver files before Flutter has installed its handler.
  // Queue them until the ready handshake; later batches go to the same shell.
  override func application(_ sender: NSApplication, openFiles filenames: [String]) {
    if documentReceiverReady {
      documentChannel?.invokeMethod("open", arguments: filenames)
    } else {
      pendingPaths.append(contentsOf: filenames)
    }
    sender.reply(toOpenOrPrint: .success)
    mainFlutterWindow?.makeKeyAndOrderFront(nil)
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
