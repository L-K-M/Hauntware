import 'package:flutter/foundation.dart';

/// The desktop shell's side panes (03 §10.2, Séance's `PaneVisibility`):
/// the fleet rail on the leading edge and the inspector on the trailing
/// one. Hidden panes leave the column and its divider to the workspace.
enum WindowPane {
  sidebar,
  inspector;
}

/// A pane flag or width that applied but was not saved: it lasts until
/// the app restarts unless a later save carries it. [message] is what
/// the failed save printed.
final class WindowPanesNotSavedException implements Exception {
  const WindowPanesNotSavedException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Whether the desktop shell's side panes show and how wide they are:
/// the composition root restores the flags and the widths from
/// `settings.json` and saves every change there; without a save
/// callback, as in most tests, they are held in memory only. A change
/// applies before it is saved, and repeating it after a failed save
/// tries the save again.
final class WindowPanesController extends ChangeNotifier {
  WindowPanesController({
    bool sidebar = true,
    bool inspector = true,
    double? sidebarWidth,
    double? inspectorWidth,
    this._saveSidebar,
    this._saveInspector,
    this._saveSidebarWidth,
    this._saveInspectorWidth,
  }) : _sidebar = sidebar,
       _inspector = inspector,
       _sidebarSaved = sidebar,
       _inspectorSaved = inspector,
       _sidebarWidth = sidebarWidth ?? defaultSidebarWidth,
       _inspectorWidth = inspectorWidth ?? defaultInspectorWidth,
       _sidebarWidthSaved = sidebarWidth ?? defaultSidebarWidth,
       _inspectorWidthSaved = inspectorWidth ?? defaultInspectorWidth;

  /// The fleet rail's width until the user resizes it, and the
  /// inspector's alongside; a launch without a stored width — or with
  /// one the file could not read as a width — starts from them, as the
  /// shell's `DesktopShell.railWidth` and `inspectorWidth` do.
  static const double defaultSidebarWidth = 260;
  static const double defaultInspectorWidth = 300;

  bool _sidebar, _inspector, _sidebarSaved, _inspectorSaved;
  double _sidebarWidth,
      _inspectorWidth,
      _sidebarWidthSaved,
      _inspectorWidthSaved;
  final Future<void> Function(bool shown)? _saveSidebar, _saveInspector;
  final Future<void> Function(double width)? _saveSidebarWidth,
      _saveInspectorWidth;

  bool get sidebarShown => _sidebar;

  bool get inspectorShown => _inspector;

  /// The fleet rail's width in logical pixels.
  double get sidebarWidth => _sidebarWidth;

  /// The inspector's width in logical pixels.
  double get inspectorWidth => _inspectorWidth;

  /// Flips [pane]; its setter applies.
  Future<void> toggle(WindowPane pane) => setShown(pane, !shownOf(pane));

  /// Whether [pane] shows right now.
  bool shownOf(WindowPane pane) => switch (pane) {
    WindowPane.sidebar => _sidebar,
    WindowPane.inspector => _inspector,
  };

  /// [pane]'s width right now, in logical pixels.
  double widthOf(WindowPane pane) => switch (pane) {
    WindowPane.sidebar => _sidebarWidth,
    WindowPane.inspector => _inspectorWidth,
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

  /// Sets [pane]'s width in logical pixels; [setShown]'s counterpart for
  /// the panes' widths, which the shell calls when a resize ends so a
  /// drag writes once rather than on every frame. Throws
  /// [WindowPanesNotSavedException] when it applied but was not saved.
  Future<void> setWidth(WindowPane pane, double width) async {
    final (current, saved, apply, save) = switch (pane) {
      WindowPane.sidebar => (
        _sidebarWidth,
        _sidebarWidthSaved,
        (double v) => _sidebarWidth = v,
        _saveSidebarWidth,
      ),
      WindowPane.inspector => (
        _inspectorWidth,
        _inspectorWidthSaved,
        (double v) => _inspectorWidth = v,
        _saveInspectorWidth,
      ),
    };
    if (width == current && width == saved) return;
    if (width != current) {
      apply(width);
      notifyListeners();
    }
    try {
      await save?.call(width);
      switch (pane) {
        case WindowPane.sidebar:
          _sidebarWidthSaved = width;
        case WindowPane.inspector:
          _inspectorWidthSaved = width;
      }
    } on Exception catch (error, stackTrace) {
      Error.throwWithStackTrace(
        WindowPanesNotSavedException('The window layout was not saved: $error'),
        stackTrace,
      );
    }
  }
}
