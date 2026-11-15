import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_desktop/ghost_desktop.dart';
import 'package:ghost_desktop/testing.dart';
import 'package:klabautermann_app/services/window_state.dart';

/// The main window's state (03 §10.2): `window_state.json` beside
/// `settings.json`, and Klabautermann's choices on ghost_desktop's shared
/// lifecycle, driven through scripted window and display adapters.
void main() {
  late Directory directory;
  late File file;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('klab-window-state-');
    file = File('${directory.path}${Platform.pathSeparator}window_state.json');
  });

  tearDown(() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  const display = GhostDisplay(workArea: Rect.fromLTWH(0, 0, 1920, 1080));

  Future<void> store(Map<String, Object?> json) =>
      file.writeAsString(jsonEncode(json));

  Future<void> settle() async {
    for (var i = 0; i < 10; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  group('window_state.json', () {
    test('lives beside settings.json under its own name', () {
      expect(windowStateFileName, 'window_state.json');
    });

    test('round-trips a snapshot through the settings writer, in the shape '
        'Séance established', () async {
      const snapshot = GhostWindowSnapshot(
        bounds: Rect.fromLTWH(10, 20, 1200, 800),
        isMaximized: true,
      );
      await windowStateFile(file).save(snapshot);

      expect(
        await file.readAsString(),
        '{"x":10.0,"y":20.0,"width":1200.0,"height":800.0,'
        '"isMaximized":true,"isFullScreen":false}',
      );
      expect(await windowStateFile(file).load(), snapshot);
      expect(
        directory.listSync().map((entity) => entity.uri.pathSegments.last),
        ['window_state.json'],
        reason: 'no temp file is left behind',
      );
    });
  });

  test('only desktops have a window to remember', () {
    expect(
      ghostDesktopPlatformFor(TargetPlatform.linux),
      GhostDesktopPlatform.linux,
    );
    expect(
      ghostDesktopPlatformFor(TargetPlatform.macOS),
      GhostDesktopPlatform.macos,
    );
    expect(
      ghostDesktopPlatformFor(TargetPlatform.windows),
      GhostDesktopPlatform.windows,
    );
    for (final platform in [
      TargetPlatform.android,
      TargetPlatform.iOS,
      TargetPlatform.fuchsia,
    ]) {
      expect(ghostDesktopPlatformFor(platform), isNull, reason: '$platform');
    }
  });

  group('restoring at launch', () {
    test('puts an on-screen frame back and leaves showing to the runner '
        'on Linux', () async {
      await store({'x': 200, 'y': 150, 'width': 1000, 'height': 700});
      final window = FakeWindowAdapter();

      final lifecycle = await restoreMainWindow(
        stateFile: file,
        platform: TargetPlatform.linux,
        window: window,
        displays: FakeDisplayAdapter(primary: display, all: const [display]),
      );

      expect(lifecycle, isNotNull);
      expect(window.boundsSet, [const Rect.fromLTWH(200, 150, 1000, 700)]);
      // The Linux and Windows runners show the window on the first frame.
      expect(window.calls, isNot(contains('show')));
      expect(window.listenerRegistered, isTrue);
      // The close is intercepted (K4): the native window holds the close
      // for the quit guard, which answers through confirmClose.
      expect(window.preventClose, isTrue);
    });

    test('asks confirmClose before closing; a veto leaves the window up, '
        'writes no state, and an OK destroys it', () async {
      var answer = false;
      final window = FakeWindowAdapter();
      final lifecycle = await restoreMainWindow(
        stateFile: file,
        platform: TargetPlatform.linux,
        window: window,
        displays: FakeDisplayAdapter(primary: display, all: const [display]),
        confirmClose: () async => answer,
      );

      // The veto saves nothing and the window survives, listener on.
      expect(await lifecycle!.close(), isFalse);
      expect(await file.exists(), isFalse);
      expect(window.calls, isNot(contains('destroy')));
      expect(window.listenerRegistered, isTrue);

      // The next close re-runs the whole path, guard included.
      answer = true;
      expect(await lifecycle.close(), isTrue);
      expect(window.calls, contains('destroy'));
      expect(await file.exists(), isTrue);
    });

    test('clamps a frame from a monitor that is gone onto the primary '
        'display', () async {
      await store({'x': 2200, 'y': 100, 'width': 1200, 'height': 800});
      final window = FakeWindowAdapter();

      await restoreMainWindow(
        stateFile: file,
        platform: TargetPlatform.linux,
        window: window,
        displays: FakeDisplayAdapter(primary: display, all: const [display]),
      );

      // Centred on the only display, at its own size.
      expect(window.boundsSet, [const Rect.fromLTWH(360, 140, 1200, 800)]);
    });

    test('pulls a frame partly off screen fully onto its display', () async {
      await store({'x': 1500, 'y': 600, 'width': 800, 'height': 600});
      final window = FakeWindowAdapter();

      await restoreMainWindow(
        stateFile: file,
        platform: TargetPlatform.linux,
        window: window,
        displays: FakeDisplayAdapter(primary: display, all: const [display]),
      );

      expect(window.boundsSet, [const Rect.fromLTWH(1120, 480, 800, 600)]);
    });

    test('shrinks a frame larger than the display that remains', () async {
      await store({'x': -100, 'y': 0, 'width': 3000, 'height': 2000});
      final window = FakeWindowAdapter();

      await restoreMainWindow(
        stateFile: file,
        platform: TargetPlatform.windows,
        window: window,
        displays: FakeDisplayAdapter(primary: display, all: const [display]),
      );

      expect(window.boundsSet.last, const Rect.fromLTWH(0, 0, 1920, 1080));
    });

    test('keeps a frame spanning two displays where it was', () async {
      await store({'x': 1500, 'y': 100, 'width': 1000, 'height': 700});
      final window = FakeWindowAdapter();

      await restoreMainWindow(
        stateFile: file,
        platform: TargetPlatform.linux,
        window: window,
        displays: FakeDisplayAdapter(
          primary: display,
          all: const [
            display,
            GhostDisplay(workArea: Rect.fromLTWH(1920, 0, 1920, 1080)),
          ],
        ),
      );

      expect(window.boundsSet, [const Rect.fromLTWH(1500, 100, 1000, 700)]);
    });

    test('stores physical pixels on Windows and places the window in '
        'logical ones', () async {
      // A 2x display: its logical work area is 1920 by 1080, so 3840 by
      // 2160 physical pixels.
      await store({'x': 400, 'y': 200, 'width': 2000, 'height': 1200});
      final window = FakeWindowAdapter()..devicePixelRatio = 2;
      const hiDpi = GhostDisplay(
        workArea: Rect.fromLTWH(0, 0, 1920, 1080),
        scaleFactor: 2,
      );

      await restoreMainWindow(
        stateFile: file,
        platform: TargetPlatform.windows,
        window: window,
        displays: FakeDisplayAdapter(primary: hiDpi, all: const [hiDpi]),
      );

      expect(window.boundsSet.last, const Rect.fromLTWH(200, 100, 1000, 600));
    });

    test(
      'on macOS places the hidden window, maximizes it, then shows it',
      () async {
        await store({
          'x': 200,
          'y': 150,
          'width': 1000,
          'height': 700,
          'isMaximized': true,
        });
        final window = FakeWindowAdapter();

        await restoreMainWindow(
          stateFile: file,
          platform: TargetPlatform.macOS,
          window: window,
          displays: FakeDisplayAdapter(primary: display, all: const [display]),
        );

        expect(
          window.calls.where(
            (call) =>
                const {'setBounds', 'maximize', 'show', 'focus'}.contains(call),
          ),
          ['setBounds', 'maximize', 'show', 'focus'],
        );
      },
    );

    test('on macOS shows the window even when restoring fails', () async {
      final window = FakeWindowAdapter()..failEnsureInitialized = true;

      await restoreMainWindow(
        stateFile: file,
        platform: TargetPlatform.macOS,
        window: window,
        displays: FakeDisplayAdapter(primary: display, all: const [display]),
      );

      expect(window.calls, containsAllInOrder(['show', 'focus']));
      expect(window.boundsSet, isEmpty);
    });

    test('opens at the runner\'s placement when nothing was saved', () async {
      final window = FakeWindowAdapter();

      await restoreMainWindow(
        stateFile: file,
        platform: TargetPlatform.linux,
        window: window,
        displays: FakeDisplayAdapter(primary: display, all: const [display]),
      );

      expect(window.boundsSet, isEmpty);
      expect(window.listenerRegistered, isTrue);
    });

    test('leaves phones alone', () async {
      final window = FakeWindowAdapter();
      for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
        final lifecycle = await restoreMainWindow(
          stateFile: file,
          platform: platform,
          window: window,
          displays: FakeDisplayAdapter(primary: display, all: const [display]),
        );
        expect(lifecycle, isNull, reason: '$platform');
      }
      expect(window.calls, isEmpty);
      expect(file.existsSync(), isFalse);
    });
  });

  group('tracking while the app runs', () {
    late FakeWindowAdapter window;
    late MemoryPersistence persistence;
    late FakeDebounceScheduler debounce;
    late GhostWindowLifecycle lifecycle;

    setUp(() async {
      window = FakeWindowAdapter();
      persistence = MemoryPersistence();
      debounce = FakeDebounceScheduler();
      lifecycle = mainWindowLifecycle(
        persistence: persistence,
        window: window,
        displays: FakeDisplayAdapter(primary: display, all: const [display]),
        platform: GhostDesktopPlatform.linux,
        scheduleDebounce: debounce.schedule,
      );
      await lifecycle.prepare();
      await lifecycle.show();
    });

    tearDown(() => lifecycle.dispose());

    test('saves the normal frame once a move settles', () async {
      window.bounds = const Rect.fromLTWH(300, 200, 1100, 750);
      window.emitMove();
      window.emitMove();
      expect(persistence.writes, isEmpty, reason: 'debounced');

      await debounce.fire();

      expect(persistence.writes, [
        const GhostWindowSnapshot(bounds: Rect.fromLTWH(300, 200, 1100, 750)),
      ]);
    });

    test('keeps the normal frame while maximized', () async {
      const normal = Rect.fromLTWH(300, 200, 1100, 750);
      window.bounds = normal;
      window.emitMove();
      await debounce.fire();

      window
        ..maximized = true
        ..bounds = const Rect.fromLTWH(0, 0, 1920, 1080);
      window.emitMaximize();
      await debounce.fire();

      expect(
        persistence.writes.last,
        const GhostWindowSnapshot(bounds: normal, isMaximized: true),
      );
    });

    test('saves on close, then lets the window go', () async {
      window.bounds = const Rect.fromLTWH(40, 30, 1000, 700);
      window.emitClose();
      await settle();

      expect(
        persistence.writes.single,
        const GhostWindowSnapshot(bounds: Rect.fromLTWH(40, 30, 1000, 700)),
      );
      // With no confirmClose wired, the intercepted close proceeds: the
      // save lands, then the window destroys itself.
      expect(window.calls, contains('destroy'));
    });
  });
}
