import 'package:flutter/foundation.dart';

/// The desktop shell's side panes (03 §10.2, Séance's `PaneVisibility`):
/// the fleet rail on the leading edge and the inspector on the trailing
/// one. Hidden panes leave the column and its divider to the workspace.
enum WindowPane {
  sidebar,
  inspector;
}

/// A pane flag that applied but was not saved: it lasts until the app
/// restarts unless a later save carries it. [message] is what the failed
/// save printed.
final class WindowPanesNotSavedException implements Exception {
  const WindowPanesNotSavedException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Whether the desktop shell's side panes show: the composition root
/// restores both flags from `settings.json` and saves every change there;
/// without a save callback, as in most tests, they are held in memory
/// only. A change applies before it is saved, and repeating it after a
/// failed save tries the save again.
final class WindowPanesController extends ChangeNotifier {
  WindowPanesController({
    bool sidebar = true,
    bool inspector = true,
    this._saveSidebar,
    this._saveInspector,
  }) : _sidebar = sidebar,
       _inspector = inspector,
       _sidebarSaved = sidebar,
       _inspectorSaved = inspector;

  bool _sidebar, _inspector, _sidebarSaved, _inspectorSaved;
  final Future<void> Function(bool shown)? _saveSidebar, _saveInspector;

  bool get sidebarShown => _sidebar;

  bool get inspectorShown => _inspector;

  /// Flips [pane]; its setter applies.
  Future<void> toggle(WindowPane pane) => setShown(pane, !shownOf(pane));

  /// Whether [pane] shows right now.
  bool shownOf(WindowPane pane) => switch (pane) {
    WindowPane.sidebar => _sidebar,
    WindowPane.inspector => _inspector,
  };

  /// Shows or hides [pane]; a no-op when it is in force and saved. Throws
  /// [WindowPanesNotSavedException] when it applied but was not saved.
  Future<void> setShown(WindowPane pane, bool shown) async {
    final (current, saved, apply, save) = switch (pane) {
      WindowPane.sidebar => (
        _sidebar,
        _sidebarSaved,
        (bool v) => _sidebar = v,
        _saveSidebar,
      ),
      WindowPane.inspector => (
        _inspector,
        _inspectorSaved,
        (bool v) => _inspector = v,
        _saveInspector,
      ),
    };
    if (shown == current && shown == saved) return;
    if (shown != current) {
      apply(shown);
      notifyListeners();
    }
    try {
      await save?.call(shown);
      switch (pane) {
        case WindowPane.sidebar:
          _sidebarSaved = shown;
        case WindowPane.inspector:
          _inspectorSaved = shown;
      }
    } on Exception catch (error, stackTrace) {
      Error.throwWithStackTrace(
        WindowPanesNotSavedException('The window layout was not saved: $error'),
        stackTrace,
      );
    }
  }
}
