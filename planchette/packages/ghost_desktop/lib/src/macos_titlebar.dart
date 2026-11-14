import 'package:flutter/foundation.dart';
import 'package:macos_window_utils/macos_window_utils.dart';

import 'macos_toolbar_band.dart';

/// The native calls behind the integrated macOS titlebar, a seam for
/// tests. The default one drives the main window through
/// macos_window_utils, whose toolbar calls act on the main window only.
abstract interface class MacosTitlebarAdapter {
  factory MacosTitlebarAdapter() = _WindowUtilsTitlebar;

  /// Makes the titlebar transparent over full-size content, hides the
  /// title, and adds an empty unified toolbar that makes the band 52 pt
  /// tall, so the traffic lights sit centred on the header drawn beneath
  /// it. Empty band space keeps AppKit's window drag and double-click
  /// zoom; the header's controls take clicks through
  /// `MacosToolbarPassthrough` views, and every other surface stays below
  /// the band ([ReserveMacosToolbarBand]).
  Future<void> install();

  /// Puts the standard titlebar back.
  Future<void> reset();
}

/// Makes the main window's titlebar part of the app (see
/// [MacosTitlebarAdapter.install]) and returns the band's state, reported
/// on the host's window method channel [channelName] (for example
/// `seance/window`).
///
/// The runner starts from a standard titlebar
/// (`MainFlutterWindowManipulator.start`), so this must run before the
/// window is first shown, while the runner still keeps it hidden. Never
/// pass a `titleBarStyle` to window_manager as well: its
/// `setTitleBarStyle` rewrites the same window properties.
///
/// Returns null when the install failed and the window keeps its standard
/// titlebar, in which case nothing in the app reserves a band. Only call
/// it on macOS, in the app's engine: a second engine without plugins has
/// no window to change. [adapter] is a test seam.
Future<MacosToolbarBandChannel?> installMacosTitlebar({
  required String channelName,
  MacosTitlebarAdapter? adapter,
}) async {
  adapter ??= MacosTitlebarAdapter();
  try {
    await adapter.install();
  } on Object catch (error) {
    debugPrint('Integrated titlebar install failed: $error');
    // A half-applied titlebar (content under a transparent bar, but no
    // toolbar to make the band) would put the traffic lights over the
    // rail with nothing reserved for them. Back to the standard one.
    try {
      await adapter.reset();
    } on Object catch (error) {
      debugPrint('Standard titlebar reset failed: $error');
    }
    return null;
  }

  // The band is only a layout hint and the install runs before the hidden
  // window is shown, so a failed query is logged, not thrown.
  final band = MacosToolbarBandChannel(
    channelName: channelName,
    onStartError: (error, _) =>
        debugPrint('Toolbar band state unavailable: $error'),
  );
  await band.start();
  return band;
}

final class _WindowUtilsTitlebar implements MacosTitlebarAdapter {
  /// Every other WindowManipulator call waits for `initialize` to have
  /// completed, so after a failed one [reset] would wait forever.
  bool _initialized = false;

  @override
  Future<void> install() async {
    await WindowManipulator.initialize();
    _initialized = true;
    await WindowManipulator.enableFullSizeContentView();
    await WindowManipulator.makeTitlebarTransparent();
    await WindowManipulator.hideTitle();
    await WindowManipulator.addToolbar();
    await WindowManipulator.setToolbarStyle(
      toolbarStyle: NSWindowToolbarStyle.unified,
    );
  }

  @override
  Future<void> reset() async {
    if (!_initialized) return;
    await WindowManipulator.removeToolbar();
    await WindowManipulator.showTitle();
    await WindowManipulator.makeTitlebarOpaque();
    await WindowManipulator.disableFullSizeContentView();
  }
}
