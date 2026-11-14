import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_desktop/ghost_desktop.dart';
import 'package:ghost_desktop/testing.dart';
import 'package:planchette_app/planchette_app.dart';
import 'package:planchette_app/services/desktop_window.dart';
import 'package:planchette_app/services/document_windows.dart';
import 'package:planchette_app/services/document_workspace.dart';
import 'package:planchette_app/theme/planchette_theme.dart';

import 'document_windows_test.dart' show FakeWindowHost;
import 'document_workspace_test.dart' show MemoryDocuments, FakeDialogs;

extension on FakeWindowAdapter {
  /// Destroys that went through; a failed one leaves the window up.
  int get destroyCalls => events.where((event) => event == 'destroy').length;
}

DesktopWindow desktopFor({
  Future<bool> Function()? confirmQuit,
  void Function(Object error)? onQuitFailed,
  VoidCallback? onFocus,
  Future<bool> Function()? closeInstead,
  Color? windowBackgroundColor,
  GhostWindowAdapter? window,
  GhostDisplayAdapter? displays,
  GhostWindowPersistence? persistence,
  GhostDesktopPlatform? platform,
  void Function() Function(Duration, Future<void> Function())? scheduleDebounce,
  Future<void> Function(String title)? setWindowTitle,
}) {
  return DesktopWindow(
    confirmQuit: confirmQuit ?? () async => true,
    onQuitFailed: onQuitFailed ?? (_) {},
    onFocus: onFocus,
    closeInstead: closeInstead,
    windowBackgroundColor: windowBackgroundColor,
    persistence: persistence ?? MemoryPersistence(),
    window: window ?? FakeWindowAdapter(),
    displays:
        displays ??
        FakeDisplayAdapter.workAreas(const [Rect.fromLTWH(0, 0, 2560, 1440)]),
    platform: platform ?? GhostDesktopPlatform.macos,
    scheduleDebounce: scheduleDebounce,
    setWindowTitle: setWindowTitle,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'failed native destroy reports and unlocks the retained workspace',
    () async {
      // Wired as main.dart wires it: the app-wide review and failure path.
      final windows = DocumentWindows(
        host: FakeWindowHost(),
        workspaceFactory: (_) =>
            DocumentWorkspace(store: MemoryDocuments(), dialogs: FakeDialogs()),
        quitApplication: () async {},
        afterFrame: () async {},
      );
      addTearDown(windows.dispose);
      await windows.start();
      final workspace = windows.windows.single.workspace;
      final tab = workspace.newDocument()!;
      final window = FakeWindowAdapter()..failDestroy = true;
      final desktop = desktopFor(
        confirmQuit: windows.confirmAllClose,
        onQuitFailed: windows.quitFailed,
        window: window,
      );
      await desktop.requestQuit();
      expect(workspace.interactionLocked, isFalse);
      expect(workspace.error, contains('destroy failed'));
      expect(workspace.documents, [tab]);
      await desktop.requestQuit();
      expect(window.destroyCalls, 0);
      window.failDestroy = false;
      await desktop.requestQuit();
      expect(window.destroyCalls, 1);
    },
  );

  test('the window coming back to the front asks for a disk check', () {
    var focused = 0;
    final desktop = desktopFor(onFocus: () => focused++);
    addTearDown(desktop.dispose);
    desktop.onWindowFocus();
    expect(focused, 1);
  });

  test(
    'the native window opens on the app surface, not the platform default',
    () {
      final desktop = desktopFor(
        windowBackgroundColor: const Color(0xff0e1415),
      );
      addTearDown(desktop.dispose);
      expect(desktop.windowOptions.backgroundColor, const Color(0xff0e1415));
      expect(desktop.windowOptions.size, const Size(1080, 760));
      expect(desktop.windowOptions.minimumSize, const Size(640, 400));
      expect(desktop.windowOptions.title, 'Planchette');
      expect(desktop.windowOptions.placement, GhostWindowPlacement.centered);
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

  test('the primary window reopens where it was closed', () async {
    const remembered = Rect.fromLTWH(220, 140, 900, 620);
    final window = FakeWindowAdapter();
    final desktop = desktopFor(
      window: window,
      persistence: MemoryPersistence(
        const GhostWindowSnapshot(bounds: remembered),
      ),
      platform: GhostDesktopPlatform.macos,
    );
    addTearDown(desktop.dispose);

    await desktop.initialize();

    // The remembered frame goes on while the window is still hidden, and
    // only then does the window come forward.
    expect(window.bounds, remembered);
    expect(
      window.calls.indexOf('setBounds'),
      lessThan(window.calls.indexOf('show')),
    );
    expect(window.calls, contains('focus'));
    expect(window.readyOptions?.placement, GhostWindowPlacement.restored);
  });

  test('with nothing saved the window opens at its defaults', () async {
    final window = FakeWindowAdapter();
    final desktop = desktopFor(window: window);
    addTearDown(desktop.dispose);

    await desktop.initialize();

    expect(window.calls, isNot(contains('setBounds')));
    expect(window.readyOptions?.placement, GhostWindowPlacement.centered);
    expect(window.readyOptions?.size, const Size(1080, 760));
  });

  test('a moved window saves the new frame after the debounce', () async {
    final pending = <Future<void> Function()>[];
    final window = FakeWindowAdapter();
    final persistence = MemoryPersistence();
    final desktop = desktopFor(
      window: window,
      persistence: persistence,
      scheduleDebounce: (_, callback) {
        pending.add(callback);
        return () => pending.remove(callback);
      },
    );
    addTearDown(desktop.dispose);
    await desktop.initialize();

    window.bounds = const Rect.fromLTWH(40, 30, 800, 500);
    window.emitMove();
    expect(persistence.writes.length, 0);
    await pending.single();
    expect(persistence.stored?.bounds, window.bounds);
  });

  test('a maximized window is remembered without its frame', () async {
    final window = FakeWindowAdapter();
    final persistence = MemoryPersistence();
    final pending = <Future<void> Function()>[];
    final desktop = desktopFor(
      window: window,
      persistence: persistence,
      confirmQuit: () async => true,
      scheduleDebounce: (_, callback) {
        pending.add(callback);
        return () => pending.remove(callback);
      },
    );
    addTearDown(desktop.dispose);
    await desktop.initialize();

    // Save a normal frame first, then maximize and quit: the remembered
    // normal frame must survive — the maximized bounds would resurrect as
    // the "normal" frame, so the flag is saved beside what was kept.
    const normal = Rect.fromLTWH(40, 30, 800, 500);
    window.bounds = normal;
    window.emitMove();
    await pending.single();
    window.maximized = true;
    // Report the maximized frame too: without it the bounds assertion
    // cannot tell "kept the normal frame" from "saved the live frame".
    window.bounds = const Rect.fromLTWH(0, 0, 2560, 1440);
    await desktop.requestQuit();

    expect(persistence.stored?.isMaximized, isTrue);
    expect(persistence.stored?.bounds, normal);
  });

  test(
    'a restore failure still lets initialize return for runWidget',
    () async {
      final window = FakeWindowAdapter()..failReadyToShow = true;
      final errors = <Object>[];
      final desktop = desktopFor(window: window, onQuitFailed: errors.add);
      addTearDown(desktop.dispose);

      // The queued restore throws, show() rescues then rethrows — and
      // initialize() must still return, because main() mounts the UI only
      // after it. The failure reaches onQuitFailed through the lifecycle's
      // onError rather than escaping as a blank-window crash.
      await desktop.initialize();

      expect(window.calls, contains('show'));
      expect(errors.single, isA<StateError>());
    },
  );

  test(
    'the close button with other windows up neither quits nor saves',
    () async {
      final window = FakeWindowAdapter();
      final persistence = MemoryPersistence();
      var confirmCalls = 0;
      final desktop = desktopFor(
        window: window,
        persistence: persistence,
        // Other windows exist: this close leaves the app running.
        closeInstead: () async => true,
        confirmQuit: () async {
          confirmCalls++;
          return true;
        },
      );
      addTearDown(desktop.dispose);
      await desktop.initialize();

      // The intercept policy armed the native close guard during prepare.
      expect(window.preventClose, isTrue);

      window.emitClose();
      await Future<void>.delayed(Duration.zero);

      expect(window.destroyCalls, 0);
      expect(confirmCalls, 0);
      expect(persistence.writes.length, 0);
    },
  );

  test('a menu quit is not intercepted by the per-window close', () async {
    final window = FakeWindowAdapter();
    final desktop = desktopFor(
      window: window,
      // Would take the close if it were the window button — a quit is not.
      closeInstead: () async => true,
    );
    addTearDown(desktop.dispose);
    await desktop.initialize();
    await desktop.requestQuit();

    expect(window.destroyCalls, 1);
  });

  // The document windows name the main window before main() initializes
  // it; window_manager's macOS plugin crashes on a title before its
  // ensureInitialized, and its pre-show options apply the default title.
  test('a title asked for before the window is ready waits for it', () async {
    final window = FakeWindowAdapter();
    final desktop = desktopFor(
      window: window,
      setWindowTitle: (title) async => window.calls.add('title $title'),
    );
    desktop
      ..setTitle('Planchette')
      ..setTitle('Untitled — Planchette');
    await Future<void>.delayed(Duration.zero);
    expect(window.calls, isEmpty);

    await desktop.initialize();
    expect(window.calls, contains('title Untitled — Planchette'));
    expect(window.calls, isNot(contains('title Planchette')));
    expect(
      window.calls.indexOf('title Untitled — Planchette'),
      greaterThan(window.calls.indexOf('waitUntilReadyToShow')),
    );
  });

  test('a window that never got ready is never sent a title', () async {
    final titles = <String>[];
    final desktop = desktopFor(
      window: FakeWindowAdapter()..failReadyToShow = true,
      setWindowTitle: (title) async => titles.add(title),
    );
    desktop.setTitle('a — Planchette');
    await desktop.initialize();
    desktop.setTitle('b — Planchette');
    await Future<void>.delayed(Duration.zero);
    expect(titles, isEmpty);
  });

  test('an unchanged title is not sent to the window again', () async {
    final titles = <String>[];
    final desktop = desktopFor(
      setWindowTitle: (title) async => titles.add(title),
    );
    await desktop.initialize();
    desktop
      ..setTitle('a — Planchette')
      ..setTitle('a — Planchette')
      ..setTitle('● a — Planchette')
      ..setTitle('● a — Planchette');
    expect(titles, ['a — Planchette', '● a — Planchette']);
  });

  test('a late failure of an older title keeps the newer one', () async {
    final titles = <String>[];
    final older = Completer<void>();
    final desktop = desktopFor(
      setWindowTitle: (title) {
        titles.add(title);
        return title == 'a — Planchette' ? older.future : Future.value();
      },
    );
    await desktop.initialize();
    desktop
      ..setTitle('a — Planchette')
      ..setTitle('b — Planchette');
    older.completeError(StateError('channel closed'));
    await Future<void>.delayed(Duration.zero);
    // The window shows b; forgetting it because a failed would resend it.
    desktop.setTitle('b — Planchette');
    expect(titles, ['a — Planchette', 'b — Planchette']);
  });

  test('a title that failed to arrive is sent again', () async {
    final titles = <String>[];
    var failNext = true;
    final desktop = desktopFor(
      setWindowTitle: (title) async {
        titles.add(title);
        if (failNext) {
          failNext = false;
          throw StateError('channel closed');
        }
      },
    );
    await desktop.initialize();
    desktop.setTitle('a — Planchette');
    await Future<void>.delayed(Duration.zero);
    desktop.setTitle('a — Planchette');
    await Future<void>.delayed(Duration.zero);
    desktop.setTitle('a — Planchette');
    expect(titles, ['a — Planchette', 'a — Planchette']);
  });

  test('overlapping close callbacks request native destruction once', () async {
    final decision = Completer<bool>();
    final window = FakeWindowAdapter();
    final desktop = desktopFor(
      window: window,
      confirmQuit: () => decision.future,
    );
    final first = desktop.requestQuit();
    final second = desktop.requestQuit();
    decision.complete(true);
    await Future.wait([first, second]);
    expect(window.destroyCalls, 1);
  });
}
