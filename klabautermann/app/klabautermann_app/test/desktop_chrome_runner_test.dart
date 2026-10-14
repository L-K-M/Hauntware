import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/services/macos_titlebar.dart';

import 'support/native_sources.dart';

/// The desktop chrome's native side (03 §10.2): the macOS runner code
/// copied from Séance for the window state and the integrated titlebar
/// (docs/SHARED.md). Only a Mac compiles it, so these checks keep the
/// wiring from silently regressing on Linux CI, and keep the settings
/// window's second engine (D32) free of the main window's handlers.
void main() {
  final mainWindow = readSource('macos/Runner/MainFlutterWindow.swift');
  final settingsWindow = readSource('macos/Runner/SettingsWindow.swift');
  final main = readSource('lib/main.dart');

  group('integrated titlebar', () {
    test('the main window serves the band on the Dart side\'s channel', () {
      expect(mainWindow, contains('name: "$windowChannelName"'));
      // ghost_desktop's MacosToolbarBandChannel asks with this method and
      // hears the full-screen edges through the other.
      expect(mainWindow, contains('call.method == "isToolbarBandVisible"'));
      expect(mainWindow, contains('result(!self.inFullScreen)'));
      expect(
        mainWindow,
        contains(
          'windowChannel?.invokeMethod("toolbarBandChanged", '
          'arguments: !value)',
        ),
      );
      for (final edge in [
        'NSWindow.willEnterFullScreenNotification',
        'NSWindow.willExitFullScreenNotification',
      ]) {
        expect(mainWindow, contains('name: $edge'), reason: edge);
      }
      // A toolbar added after a restore into full screen starts hidden.
      expect(
        mainWindow,
        contains(
          RegExp(
            r'override var toolbar: NSToolbar\? \{\s*'
            r'didSet \{ toolbar\?\.isVisible = !inFullScreen \}',
          ),
        ),
      );
    });

    test('macos_window_utils hosts the main window\'s Flutter view and '
        'starts from a standard titlebar', () {
      expect(mainWindow, contains('import macos_window_utils'));
      final host = mainWindow.indexOf(
        'self.contentViewController = windowUtilsController',
      );
      final start = mainWindow.indexOf(
        'MainFlutterWindowManipulator.start(mainFlutterWindow: self)',
      );
      final plugins = mainWindow.indexOf(
        'RegisterGeneratedPlugins(registry: flutterViewController)',
      );
      expect(host, isNonNegative);
      expect(start, greaterThan(host));
      expect(plugins, greaterThan(start));
    });

    test('the settings window keeps a plain window', () {
      for (final name in [
        windowChannelName,
        'MacOSWindowUtilsViewController',
        'MainFlutterWindowManipulator',
        'toolbarBandChanged',
      ]) {
        expect(settingsWindow, isNot(contains(name)), reason: name);
      }
    });

    test('the app installs it before the window is shown, and the settings '
        'window\'s engine never does', () {
      final branch = main.indexOf('await runSettingsWindow();');
      final install = main.indexOf('await installMacosTitlebar()');
      final restore = main.indexOf('await restoreMainWindow(');
      expect(branch, isNonNegative);
      expect(install, greaterThan(branch));
      expect(restore, greaterThan(install));
      expect(main, contains('toolbarBand: toolbarBand,'));
    });
  });

  group('window state', () {
    test('the macOS window stays hidden until Dart has placed it', () {
      expect(mainWindow, contains('import window_manager'));
      expect(
        mainWindow,
        contains(
          RegExp(
            r'override public func order\(_ place: NSWindow\.OrderingMode, '
            r'relativeTo otherWin: Int\) \{\s*'
            r'super\.order\(place, relativeTo: otherWin\)\s*'
            r'hiddenWindowAtLaunch\(\)\s*\}',
          ),
        ),
      );
      // Only the main window waits for Dart; the settings window shows
      // itself when it opens.
      expect(settingsWindow, isNot(contains('hiddenWindowAtLaunch')));
    });

    test('the app restores the window before runApp, and the settings '
        'window\'s engine never does', () {
      final branch = main.indexOf('await runSettingsWindow();');
      final restore = main.indexOf('await restoreMainWindow(');
      final runApp = main.indexOf('runApp(');
      expect(branch, isNonNegative);
      expect(restore, greaterThan(branch));
      expect(runApp, greaterThan(restore));
      expect(main, contains('stateFile: supportFile(windowStateFileName)'));
    });
  });
}
