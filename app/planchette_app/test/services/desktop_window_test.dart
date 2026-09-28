import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planchette_app/planchette_app.dart';
import 'package:planchette_app/services/desktop_window.dart';
import 'package:planchette_app/services/document_workspace.dart';
import 'package:planchette_app/theme/planchette_theme.dart';

import 'document_workspace_test.dart' show MemoryDocuments, FakeDialogs;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'failed native destroy reports and unlocks the retained workspace',
    () async {
      final workspace = DocumentWorkspace(
        store: MemoryDocuments(),
        dialogs: FakeDialogs(),
      );
      addTearDown(workspace.dispose);
      final tab = workspace.newDocument()!;
      var attempts = 0;
      final desktop = DesktopWindow(
        confirmQuit: workspace.confirmQuit,
        onQuitFailed: workspace.quitFailed,
        destroyWindow: () async {
          attempts++;
          throw StateError('native close failed');
        },
      );
      await desktop.requestQuit();
      expect(workspace.interactionLocked, isFalse);
      expect(workspace.error, contains('native close failed'));
      expect(workspace.documents, [tab]);
      await desktop.requestQuit();
      expect(attempts, 2);
    },
  );

  test(
    'the native window opens on the app surface, not the platform default',
    () {
      final desktop = DesktopWindow(
        confirmQuit: () async => true,
        onQuitFailed: (_) {},
        windowBackgroundColor: const Color(0xff0e1415),
      );
      addTearDown(desktop.dispose);
      expect(desktop.windowOptions.backgroundColor, const Color(0xff0e1415));
      expect(desktop.windowOptions.size, const Size(1080, 760));
      expect(desktop.windowOptions.minimumSize, const Size(640, 400));
      expect(desktop.windowOptions.title, 'Planchette');
    },
  );

  test('the window backdrop is the surface the app paints', () {
    for (final brightness in Brightness.values) {
      expect(
        windowBackdrop(brightness),
        planchetteTheme(brightness).scaffoldBackgroundColor,
      );
    }
    // The app's own pages: a second theme builder shadowing the imported one
    // would still pass the check above.
    expect(windowBackdrop(Brightness.light), PlanchettePalette.parchment.page);
    expect(windowBackdrop(Brightness.dark), PlanchettePalette.seance.page);
  });

  test(
    'a forced theme mode paints the window that theme, not the system one',
    () {
      expect(effectiveBrightness(ThemeMode.light), Brightness.light);
      expect(effectiveBrightness(ThemeMode.dark), Brightness.dark);
      expect(
        windowBackdrop(effectiveBrightness(ThemeMode.dark)),
        windowBackdrop(Brightness.dark),
      );
    },
  );

  test('overlapping close callbacks request native destruction once', () async {
    final decision = Completer<bool>();
    var destroys = 0;
    final desktop = DesktopWindow(
      confirmQuit: () => decision.future,
      onQuitFailed: (_) {},
      destroyWindow: () async {
        destroys++;
      },
    );
    final first = desktop.requestQuit();
    final second = desktop.requestQuit();
    decision.complete(true);
    await Future.wait([first, second]);
    expect(destroys, 1);
  });
}
