import 'package:flutter_test/flutter_test.dart';

import 'support/native_sources.dart';

/// The desktop chrome's native side (03 §10.2): the macOS runner code
/// copied from Séance for the window state (docs/SHARED.md). Only a Mac
/// compiles it, so these checks keep the wiring from silently regressing
/// on Linux CI, and keep the settings window's second engine (D32) free
/// of the main window's handlers.
void main() {
  final mainWindow = readSource('macos/Runner/MainFlutterWindow.swift');
  final settingsWindow = readSource('macos/Runner/SettingsWindow.swift');
  final main = readSource('lib/main.dart');

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
