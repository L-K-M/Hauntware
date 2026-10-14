import 'package:flutter/foundation.dart';
import 'package:ghost_desktop/ghost_desktop.dart' show MacosToolbarBandChannel;
import 'package:macos_window_utils/macos_window_utils.dart';

/// The `klabautermann/window` method channel (04 §12.3), which
/// ghost_desktop's [MacosToolbarBandChannel] listens on. The Swift side
/// lives in `MainFlutterWindow.swift`.
const String windowChannelName = 'klabautermann/window';

/// Makes the main window's titlebar part of the app, the way Séance's and
/// Poltergeist's are (Séance's `services/macos_titlebar.dart`): content
/// under a transparent titlebar, the title hidden, and an empty unified
/// toolbar that makes the band 52 pt tall, so the traffic lights sit
/// centred in it. The band stays empty and keeps AppKit's window drag and
/// double-click zoom; the app keeps its content below it
/// (`ReserveMacosToolbarBand`).
///
/// The runner starts from a standard titlebar
/// (`MainFlutterWindowManipulator.start`), so this must run before the
/// window is first shown: `main` calls it ahead of `restoreMainWindow`,
/// while the runner still keeps the window hidden. Never pass a
/// `titleBarStyle` to window_manager as well: its `setTitleBarStyle`
/// rewrites the same window properties.
///
/// Returns the band's state, or null when the install failed and the
/// window keeps its standard titlebar, in which case nothing in the app
/// reserves a band. Only call it on macOS, in the app's engine: the
/// settings window's engine registers no plugins.
Future<MacosToolbarBandChannel?> installMacosTitlebar({
  MacosTitlebarAdapter? adapter,
  String channelName = windowChannelName,
}) async {
  adapter ??= _WindowUtilsTitlebar();
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

/// The native calls behind [installMacosTitlebar], a seam for tests.
abstract interface class MacosTitlebarAdapter {
  /// Makes the titlebar transparent over full-size content and adds the
  /// empty unified toolbar.
  Future<void> install();

  /// Puts the standard titlebar back.
  Future<void> reset();
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
