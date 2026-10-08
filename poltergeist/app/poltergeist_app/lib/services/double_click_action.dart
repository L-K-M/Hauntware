/// The persisted "Double-click action" preference (02 §2.6 —
/// Transmit's default-behavior-as-preference): what the Open verb
/// does to a FILE under every activation gesture (double-click,
/// ⌘↓/⌘O on macOS, Enter on Windows/Linux). Folders never consult it —
/// they always navigate.
///
/// Read at every file open by [PaneController.openEntry] through the
/// tab's live `doubleClickAction` field; the owning strip stamps the
/// setting on its tabs. The Settings → Editing dropdown (06 §8) writes it
/// through `DoubleClickActionController`, which persists it in
/// `AppPreferences`.
enum DoubleClickAction {
  /// Open — the default. Local files launch in the OS default
  /// application through the engine's shell-open seam; remote files run
  /// 06 §4.2's checkout chain and open the result.
  open,

  /// Edit in Poltergeist — the built-in editor, on a local file directly
  /// and on a remote file through its capped checkout (06 §4.2).
  edit,

  /// Transfer to other pane — offered and persisted, but a file open
  /// still answers the not-yet notice: nothing queues the transfer.
  transfer,

  /// Do nothing — a file activation is exactly that: inert.
  nothing,
}
