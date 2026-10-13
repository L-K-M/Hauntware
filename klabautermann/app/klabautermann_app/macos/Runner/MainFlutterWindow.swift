import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    // Séance's keyboard and accessibility compatibility controller
    // (KlabautermannFlutterViewController.m, docs/SHARED.md): it keeps
    // injected Command shortcuts intact and invalidates native text fields
    // before Flutter destroys their accessibility tree.
    let flutterViewController = KlabautermannFlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
